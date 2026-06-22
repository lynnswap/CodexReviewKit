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

        let turnScoped = try decodeNotification("""
        {
          "method": "future/turnScoped",
          "params": {
            "turnId": "turn-1",
            "value": "raw"
          }
        }
        """)

        guard case .itemUpdated(let turnScopedSeed) = try #require(turnScoped.domainEvents().first) else {
            Issue.record("expected turn-scoped unknown item update")
            return
        }
        #expect(turnScopedSeed.id.rawValue == "turn-1:future/turnScoped")
    }

    @Test func preservesNonObjectRawParams() throws {
        let arrayParams = try decodeNotification("""
        {
          "method": "future/positional",
          "params": ["alpha", 2]
        }
        """)

        #expect(arrayParams.rawPayload == .array([.string("alpha"), .int(2)]))
        #expect(arrayParams.payload.rawValue == .array([.string("alpha"), .int(2)]))
        guard case .itemUpdated(let arraySeed) = try #require(arrayParams.domainEvents().first) else {
            Issue.record("expected unknown event for array params")
            return
        }
        if case .unknown(let unknown) = arraySeed.content {
            #expect(unknown.detail == "[\"alpha\",2]")
        } else {
            Issue.record("expected unknown array content")
        }

        let scalarParams = try decodeNotification("""
        {
          "method": "future/scalar",
          "params": "raw"
        }
        """)

        #expect(scalarParams.rawPayload == .string("raw"))
        #expect(scalarParams.payload.rawValue == .string("raw"))

        let nullParams = try decodeNotification("""
        {
          "method": "future/null",
          "params": null
        }
        """)

        #expect(nullParams.rawPayload == .null)
        #expect(nullParams.payload.rawValue == .null)
        guard case .itemUpdated(let nullSeed) = try #require(nullParams.domainEvents().first) else {
            Issue.record("expected unknown event for null params")
            return
        }
        if case .unknown(let unknown) = nullSeed.content {
            #expect(unknown.detail == "null")
        } else {
            Issue.record("expected unknown null content")
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
        let turnStarted = try decodeNotification("""
        {
          "method": "turn/started",
          "params": {
            "threadId": "thread-1",
            "turn": {
              "id": "turn-1"
            },
            "model": "gpt-5"
          }
        }
        """)

        guard case .runStarted(let turnID, let reviewThreadID, let model) = try #require(turnStarted.domainEvents().first) else {
            Issue.record("expected turn start")
            return
        }
        #expect(turnID.rawValue == "turn-1")
        #expect(reviewThreadID?.rawValue == "thread-1")
        #expect(model == "gpt-5")

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

        let commandFailed = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "cmd-2",
              "type": "commandExecution",
              "command": "swift test",
              "aggregatedOutput": "",
              "exitCode": 1
            }
          }
        }
        """)

        guard case .itemCompleted(let failedSeed) = try #require(commandFailed.domainEvents().first) else {
            Issue.record("expected failed command item completion")
            return
        }
        #expect(failedSeed.phase == .failed)

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

        let fragmentedApproval = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "approval-2",
              "type": "hookPrompt",
              "fragments": [
                {
                  "text": "Allow file write?"
                }
              ]
            }
          }
        }
        """)

        guard case .itemCompleted(let fragmentedApprovalSeed) = try #require(fragmentedApproval.domainEvents().first) else {
            Issue.record("expected fragmented approval completion")
            return
        }
        if case .approval(let approval) = fragmentedApprovalSeed.content {
            #expect(approval.title == "Allow file write?")
        } else {
            Issue.record("expected fragmented approval content")
        }

        let userMessage = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "user-1",
              "type": "userMessage",
              "content": [
                {
                  "text": "Please review this diff"
                }
              ]
            }
          }
        }
        """)

        guard case .itemCompleted(let userSeed) = try #require(userMessage.domainEvents().first) else {
            Issue.record("expected user message completion")
            return
        }
        if case .message(let message) = userSeed.content {
            #expect(message.text == "Please review this diff")
        } else {
            Issue.record("expected user message content")
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

        let processOutput = try decodeNotification("""
        {
          "method": "process/outputDelta",
          "params": {
            "processHandle": "process-1",
            "deltaBase64": "\(encoded)"
          }
        }
        """)

        guard case .textDelta(let processItemID, _, _, _, _) = try #require(processOutput.domainEvents().first) else {
            Issue.record("expected process output delta")
            return
        }
        #expect(processItemID.rawValue == "process-1")

        let bareCompletion = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution"
            }
          }
        }
        """)

        #expect(bareCompletion.domainEvents().isEmpty)

        let explicitEmptyAggregatedOutput = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "aggregatedOutput": ""
            }
          }
        }
        """)

        guard case .itemCompleted(let explicitEmptySeed) = try #require(explicitEmptyAggregatedOutput.domainEvents().first) else {
            Issue.record("expected explicit empty aggregate to complete command")
            return
        }
        #expect(explicitEmptySeed.phase == .completed)
        if case .command(let command) = explicitEmptySeed.content {
            #expect(command.output.isEmpty)
        } else {
            Issue.record("expected command content")
        }

        let emptyAggregatedOutputCompletion = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "completedAtMs": 2000,
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test",
              "aggregatedOutput": "",
              "exitCode": 0,
              "durationMs": 1000
            }
          }
        }
        """)

        guard case .itemCompleted(let emptyOutputSeed) = try #require(emptyAggregatedOutputCompletion.domainEvents().first) else {
            Issue.record("expected empty-output command completion with lifecycle metadata")
            return
        }
        #expect(emptyOutputSeed.phase == .completed)
        #expect(emptyOutputSeed.completedAt == Date(timeIntervalSince1970: 2))
        #expect(emptyOutputSeed.durationMs == 1000)
        if case .command(let command) = emptyOutputSeed.content {
            #expect(command.command == "swift test")
            #expect(command.output.isEmpty)
            #expect(command.exitCode == 0)
        } else {
            Issue.record("expected command content")
        }
    }

    @Test func preservesFailedCommandCompletionWithEmptyAggregatedOutput() throws {
        let failed = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test",
              "aggregatedOutput": "",
              "exitCode": 1
            }
          }
        }
        """)

        guard case .itemCompleted(let seed) = try #require(failed.domainEvents().first) else {
            Issue.record("expected failed command completion")
            return
        }
        #expect(seed.phase == .failed)
        if case .command(let command) = seed.content {
            #expect(command.command == "swift test")
            #expect(command.output.isEmpty)
            #expect(command.exitCode == 1)
        } else {
            Issue.record("expected command content")
        }
    }

    @Test @MainActor func emptyCommandCompletionPreservesStreamedOutputAndCompletesItem() throws {
        let started = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test"
            }
          }
        }
        """)

        let delta = try decodeNotification("""
        {
          "method": "item/commandExecution/outputDelta",
          "params": {
            "itemId": "cmd-1",
            "delta": "streamed output"
          }
        }
        """)

        let completed = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test",
              "aggregatedOutput": ""
            }
          }
        }
        """)

        let timeline = ReviewTimeline()
        for event in started.domainEvents() + delta.domainEvents() + completed.domainEvents() {
            timeline.apply(event)
        }

        let item = try #require(timeline.item(for: "cmd-1"))
        #expect(item.phase == .completed)
        if case .command(let command) = item.content {
            #expect(command.output == "streamed output")
            #expect(command.exitCode == nil)
        } else {
            Issue.record("expected command content")
        }
    }

    @Test @MainActor func successOnlyEmptyCommandCompletionPreservesStreamedOutputAndCompletesItem() throws {
        let started = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test"
            }
          }
        }
        """)

        let delta = try decodeNotification("""
        {
          "method": "item/commandExecution/outputDelta",
          "params": {
            "itemId": "cmd-1",
            "delta": "streamed output"
          }
        }
        """)

        let completed = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test",
              "aggregatedOutput": "",
              "success": true
            }
          }
        }
        """)

        let timeline = ReviewTimeline()
        for event in started.domainEvents() + delta.domainEvents() + completed.domainEvents() {
            timeline.apply(event)
        }

        let item = try #require(timeline.item(for: "cmd-1"))
        #expect(item.phase == .completed)
        if case .command(let command) = item.content {
            #expect(command.output == "streamed output")
            #expect(command.exitCode == nil)
        } else {
            Issue.record("expected command content")
        }
    }

    @Test @MainActor func commandOnlyCompletionPreservesStreamedOutputAndCompletesItem() throws {
        let started = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test"
            }
          }
        }
        """)

        let delta = try decodeNotification("""
        {
          "method": "item/commandExecution/outputDelta",
          "params": {
            "itemId": "cmd-1",
            "delta": "streamed output"
          }
        }
        """)

        let completed = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test"
            }
          }
        }
        """)

        let timeline = ReviewTimeline()
        for event in started.domainEvents() + delta.domainEvents() + completed.domainEvents() {
            timeline.apply(event)
        }

        let item = try #require(timeline.item(for: "cmd-1"))
        #expect(item.phase == .completed)
        if case .command(let command) = item.content {
            #expect(command.command == "swift test")
            #expect(command.output == "streamed output")
            #expect(command.exitCode == nil)
        } else {
            Issue.record("expected command content")
        }
    }

    @Test func preservesReasoningDeltaIndexesInItemIDs() throws {
        let summary = try decodeNotification("""
        {
          "method": "item/reasoning/summaryTextDelta",
          "params": {
            "itemId": "reasoning-1",
            "summaryIndex": 2,
            "delta": "summary"
          }
        }
        """)

        guard case .textDelta(let summaryItemID, _, _, _, _) = try #require(summary.domainEvents().first) else {
            Issue.record("expected summary reasoning delta")
            return
        }
        #expect(summaryItemID.rawValue == "reasoning-1:summary:2")

        let raw = try decodeNotification("""
        {
          "method": "item/reasoning/textDelta",
          "params": {
            "itemId": "reasoning-1",
            "contentIndex": 3,
            "delta": "raw"
          }
        }
        """)

        guard case .textDelta(let rawItemID, _, _, _, _) = try #require(raw.domainEvents().first) else {
            Issue.record("expected raw reasoning delta")
            return
        }
        #expect(rawItemID.rawValue == "reasoning-1:content:3")
    }

    @Test func completesReasoningPartsWithDeltaItemIDs() throws {
        let completed = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "completedAtMs": 3000,
            "item": {
              "id": "reasoning-1",
              "type": "reasoning",
              "summary": ["first final", "summary replacement"],
              "content": ["raw final", "other raw", "raw chain plus final"]
            }
          }
        }
        """)

        let events = completed.domainEvents()
        let seeds = events.compactMap { event -> ReviewTimelineItemSeed? in
            guard case .itemCompleted(let seed) = event else {
                return nil
            }
            return seed
        }

        #expect(seeds.count == 5)
        #expect(seeds.map(\.id.rawValue) == [
            "reasoning-1:summary:0",
            "reasoning-1:summary:1",
            "reasoning-1:content:0",
            "reasoning-1:content:1",
            "reasoning-1:content:2"
        ])
        #expect(seeds.contains { $0.id.rawValue == "reasoning-1" } == false)
        #expect(seeds.allSatisfy { $0.phase == .completed })
        #expect(seeds.allSatisfy { $0.completedAt == Date(timeIntervalSince1970: 3) })

        let reasoning = seeds.compactMap { seed -> ReviewTimelineItem.Reasoning? in
            guard case .reasoning(let content) = seed.content else {
                return nil
            }
            return content
        }

        #expect(reasoning.map(\.text) == [
            "first final",
            "summary replacement",
            "raw final",
            "other raw",
            "raw chain plus final"
        ])
        #expect(reasoning.map(\.style) == [.summary, .summary, .raw, .raw, .raw])
    }

    @Test func ignoresReasoningParentStartsAndUpdatesWithoutPartParentContentOrLifecycleMetadata() throws {
        for method in ["item/started", "item/updated"] {
            let notification = try decodeNotification("""
            {
              "method": "\(method)",
              "params": {
                "item": {
                  "id": "reasoning-1",
                  "type": "reasoning"
                }
              }
            }
            """)

            #expect(notification.domainEvents().isEmpty)
        }
    }

    @Test @MainActor func statusOnlyReasoningUpdateCompletesExistingParent() throws {
        let started = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "reasoning-1",
              "type": "reasoning",
              "text": "parent reasoning"
            }
          }
        }
        """)

        let failed = try decodeNotification("""
        {
          "method": "item/updated",
          "params": {
            "item": {
              "id": "reasoning-1",
              "type": "reasoning",
              "status": "failed"
            }
          }
        }
        """)

        guard case .itemStarted(let startSeed) = try #require(started.domainEvents().first),
              case .itemUpdated(let updateSeed) = try #require(failed.domainEvents().first)
        else {
            Issue.record("expected reasoning start and update")
            return
        }
        #expect(updateSeed.phase == .failed)

        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(startSeed))
        timeline.apply(.itemUpdated(updateSeed))
        let item = try #require(timeline.item(for: "reasoning-1"))
        #expect(item.phase == .failed)
        if case .reasoning(let reasoning) = item.content {
            #expect(reasoning.text == "parent reasoning")
        } else {
            Issue.record("expected reasoning content")
        }
    }

    @Test @MainActor func successAndErrorReasoningUpdatesCompleteExistingParent() throws {
        for (field, expectedPhase) in [
            (#""success": true"#, ReviewItemPhase.completed),
            (#""error": "boom""#, ReviewItemPhase.failed)
        ] {
            let started = try decodeNotification("""
            {
              "method": "item/started",
              "params": {
                "item": {
                  "id": "reasoning-1",
                  "type": "reasoning",
                  "text": "parent reasoning"
                }
              }
            }
            """)

            let lifecycleUpdate = try decodeNotification("""
            {
              "method": "item/updated",
              "params": {
                "item": {
                  "id": "reasoning-1",
                  "type": "reasoning",
                  \(field)
                }
              }
            }
            """)

            guard case .itemStarted(let startSeed) = try #require(started.domainEvents().first),
                  case .itemUpdated(let updateSeed) = try #require(lifecycleUpdate.domainEvents().first)
            else {
                Issue.record("expected reasoning start and lifecycle update")
                return
            }
            #expect(updateSeed.phase == expectedPhase)

            let timeline = ReviewTimeline()
            timeline.apply(.itemStarted(startSeed))
            timeline.apply(.itemUpdated(updateSeed))
            let item = try #require(timeline.item(for: "reasoning-1"))
            #expect(item.phase == expectedPhase)
            if case .reasoning(let reasoning) = item.content {
                #expect(reasoning.text == "parent reasoning")
            } else {
                Issue.record("expected reasoning content")
            }
        }
    }

    @Test @MainActor func completesReasoningParentWithBareCompletion() throws {
        let parentText = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "reasoning-2",
              "type": "reasoning",
              "text": "parent reasoning"
            }
          }
        }
        """)

        guard case .itemStarted(let startSeed) = try #require(parentText.domainEvents().first) else {
            Issue.record("expected parent reasoning start")
            return
        }
        #expect(startSeed.id.rawValue == "reasoning-2")
        if case .reasoning(let reasoning) = startSeed.content {
            #expect(reasoning.text == "parent reasoning")
        } else {
            Issue.record("expected reasoning content")
        }

        let bareCompletion = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "reasoning-2",
              "type": "reasoning"
            }
          }
        }
        """)

        guard case .itemCompleted(let completionSeed) = try #require(bareCompletion.domainEvents().first) else {
            Issue.record("expected bare reasoning completion")
            return
        }
        #expect(completionSeed.id.rawValue == "reasoning-2")
        #expect(completionSeed.phase == .completed)
        #expect(completionSeed.completedAt == nil)

        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(startSeed))
        timeline.apply(.itemCompleted(completionSeed))
        let item = try #require(timeline.item(for: "reasoning-2"))
        #expect(item.phase == .completed)
        if case .reasoning(let reasoning) = item.content {
            #expect(reasoning.text == "parent reasoning")
        } else {
            Issue.record("expected timeline reasoning content")
        }
    }

    @Test func doesNotDuplicatePlainStringMessageContentFragments() throws {
        let notification = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "message-1",
              "type": "agentMessage",
              "content": [
                "Line one",
                "Line two"
              ]
            }
          }
        }
        """)

        guard case .itemCompleted(let seed) = try #require(notification.domainEvents().first) else {
            Issue.record("expected message completion")
            return
        }
        if case .message(let message) = seed.content {
            #expect(message.text == "Line one\nLine two")
        } else {
            Issue.record("expected message content")
        }
    }

    @Test func mapsPartialProgressUpdatesToScopedItems() throws {
        let toolProgress = try decodeNotification("""
        {
          "method": "item/mcpToolCall/progress",
          "params": {
            "itemId": "tool-1",
            "message": "Reading review job"
          }
        }
        """)

        guard case .itemUpdated(let toolSeed) = try #require(toolProgress.domainEvents().first) else {
            Issue.record("expected tool progress update")
            return
        }
        #expect(toolSeed.id.rawValue == "tool-1:progress")
        #expect(toolSeed.family == .tool)
        if case .toolCall(let tool) = toolSeed.content {
            #expect(tool.result == "Reading review job")
            #expect(tool.server == nil)
            #expect(tool.tool == nil)
        } else {
            Issue.record("expected tool progress content")
        }

        let filePatch = try decodeNotification("""
        {
          "method": "item/fileChange/patchUpdated",
          "params": {
            "itemId": "file-1",
            "changes": [
              {
                "path": "Sources/App.swift",
                "kind": "modify",
                "diff": "diff --git"
              }
            ]
          }
        }
        """)

        guard case .itemUpdated(let fileSeed) = try #require(filePatch.domainEvents().first) else {
            Issue.record("expected file patch update")
            return
        }
        #expect(fileSeed.id.rawValue == "file-1:patch")
        #expect(fileSeed.family == .fileChange)
        if case .fileChange(let fileChange) = fileSeed.content {
            #expect(fileChange.title == "Sources/App.swift")
            #expect(fileChange.output == "modify\nSources/App.swift\ndiff --git")
        } else {
            Issue.record("expected file patch content")
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

        let deprecation = try decodeNotification("""
        {
          "method": "deprecationNotice",
          "params": {
            "turnId": "turn-5",
            "summary": "Deprecated setting",
            "details": "Use the replacement setting."
          }
        }
        """)

        guard case .itemUpdated(let deprecationSeed) = try #require(deprecation.domainEvents().first) else {
            Issue.record("expected deprecation diagnostic update")
            return
        }
        if case .diagnostic(let diagnostic) = deprecationSeed.content {
            #expect(diagnostic.message == "Deprecated setting\nUse the replacement setting.")
        } else {
            Issue.record("expected deprecation diagnostic content")
        }

        let warning = try decodeNotification("""
        {
          "method": "warning",
          "params": {
            "turnId": "turn-5",
            "message": "Model warning"
          }
        }
        """)

        guard case .itemUpdated(let warningSeed) = try #require(warning.domainEvents().first) else {
            Issue.record("expected warning diagnostic update")
            return
        }
        #expect(warningSeed.id.rawValue == "turn-5:warning")
        #expect(deprecationSeed.id.rawValue == "turn-5:deprecationNotice")
        #expect(warningSeed.id != deprecationSeed.id)

        let rerouted = try decodeNotification("""
        {
          "method": "model/rerouted",
          "params": {
            "turnId": "turn-6",
            "fromModel": "gpt-5",
            "toModel": "gpt-5.1",
            "reason": "policy"
          }
        }
        """)

        guard case .itemUpdated(let reroutedSeed) = try #require(rerouted.domainEvents().first) else {
            Issue.record("expected model reroute diagnostic")
            return
        }
        if case .diagnostic(let diagnostic) = reroutedSeed.content {
            #expect(diagnostic.message == "gpt-5 -> gpt-5.1\npolicy")
        } else {
            Issue.record("expected model reroute diagnostic content")
        }

        let verification = try decodeNotification("""
        {
          "method": "model/verification",
          "params": {
            "turnId": "turn-7",
            "verifications": ["capability", "safety"]
          }
        }
        """)

        guard case .itemUpdated(let verificationSeed) = try #require(verification.domainEvents().first) else {
            Issue.record("expected model verification diagnostic")
            return
        }
        if case .diagnostic(let diagnostic) = verificationSeed.content {
            #expect(diagnostic.message == "capability\nsafety")
        } else {
            Issue.record("expected model verification diagnostic content")
        }
    }

    @Test func mapsTurnPlanUpdatesToPlanContent() throws {
        let notification = try decodeNotification("""
        {
          "method": "turn/plan/updated",
          "params": {
            "turnId": "turn-1",
            "plan": [
              {
                "step": "Inspect diff",
                "status": "inProgress"
              },
              {
                "step": "Write findings",
                "status": "pending"
              }
            ]
          }
        }
        """)

        let events = notification.domainEvents()
        guard case .itemUpdated(let seed) = try #require(events.first) else {
            Issue.record("expected plan item update")
            return
        }
        #expect(seed.id.rawValue == "turn-1:turn/plan/updated")
        #expect(seed.kind == .plan)
        #expect(seed.family == .plan)
        if case .plan(let plan) = seed.content {
            #expect(plan.markdown == "[inProgress] Inspect diff\n[pending] Write findings")
        } else {
            Issue.record("expected plan content")
        }

        let diff = try decodeNotification("""
        {
          "method": "turn/diff/updated",
          "params": {
            "turnId": "turn-1",
            "diff": "diff --git"
          }
        }
        """)

        guard case .itemUpdated(let diffSeed) = try #require(diff.domainEvents().first) else {
            Issue.record("expected diff item update")
            return
        }
        #expect(diffSeed.id.rawValue == "turn-1:turn/diff/updated")
        #expect(diffSeed.id != seed.id)
    }

    @Test func mapsTerminalThreadNotificationsBeforeUnknownFallback() throws {
        let closed = try decodeNotification("""
        {
          "method": "thread/closed",
          "params": {
            "threadId": "thread-1"
          }
        }
        """)

        guard case .reviewFailed(let closedMessage) = try #require(closed.domainEvents().first) else {
            Issue.record("expected thread closed failure")
            return
        }
        #expect(closedMessage.isEmpty)

        let notLoaded = try decodeNotification("""
        {
          "method": "thread/status/changed",
          "params": {
            "threadId": "thread-1",
            "status": {
              "type": "notLoaded"
            }
          }
        }
        """)

        guard case .reviewFailed(let notLoadedMessage) = try #require(notLoaded.domainEvents().first) else {
            Issue.record("expected notLoaded failure")
            return
        }
        #expect(notLoadedMessage == "notLoaded")

        let interrupted = try decodeNotification("""
        {
          "method": "thread/status/changed",
          "params": {
            "threadId": "thread-1",
            "status": {
              "type": "interrupted"
            }
          }
        }
        """)

        guard case .reviewCancelled(let interruptedMessage) = try #require(interrupted.domainEvents().first) else {
            Issue.record("expected interrupted cancellation")
            return
        }
        #expect(interruptedMessage == "interrupted")

        let systemError = try decodeNotification("""
        {
          "method": "thread/status/changed",
          "params": {
            "threadId": "thread-1",
            "status": {
              "type": "systemError"
            }
          }
        }
        """)

        guard case .itemUpdated(let systemErrorSeed) = try #require(systemError.domainEvents().first) else {
            Issue.record("expected systemError diagnostic update")
            return
        }
        #expect(systemErrorSeed.family == .diagnostic)
        #expect(systemErrorSeed.phase == .running)
        if case .diagnostic(let diagnostic) = systemErrorSeed.content {
            #expect(diagnostic.message == "systemError")
        } else {
            Issue.record("expected systemError diagnostic content")
        }
    }

    @Test func ignoresReasoningSummaryBoundaryNotifications() throws {
        let notification = try decodeNotification("""
        {
          "method": "item/reasoning/summaryPartAdded",
          "params": {
            "itemId": "reasoning-1",
            "summaryIndex": 1
          }
        }
        """)

        #expect(notification.domainEvents().isEmpty)
        #expect(notification.payload.rawFields["summaryIndex"] == .int(1))
    }

    @Test func ignoresAutoApprovalReviewBoundaryNotifications() throws {
        for method in ["item/autoApprovalReview/started", "item/autoApprovalReview/completed"] {
            let notification = try decodeNotification("""
            {
              "method": "\(method)",
              "params": {
                "itemId": "approval-review-1"
              }
            }
            """)

            #expect(notification.domainEvents().isEmpty)
            #expect(notification.payload.rawFields["itemId"] == .string("approval-review-1"))
        }
    }
}

private func decodeNotification(_ json: String) throws -> AppServerWireReviewNotification {
    try JSONDecoder().decode(AppServerWireReviewNotification.self, from: Data(json.utf8))
}
