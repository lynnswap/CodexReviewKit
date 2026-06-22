import Foundation
import Testing
@testable import CodexReviewAppServerWire
import CodexReviewDomain

@Suite("app-server wire events")
struct AppServerWireEventTests {
    @Test func preservesUnknownItemKindRawValue() throws {
        let json = """
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "future-1",
              "type": "futureTool"
            }
          }
        }
        """.data(using: .utf8)!

        let notification = try JSONDecoder().decode(AppServerWireReviewNotification.self, from: json)
        let events = notification.domainEvents()

        guard case .itemStarted(let seed) = try #require(events.first) else {
            Issue.record("expected started item")
            return
        }
        #expect(seed.kind.rawValue == "futureTool")
        #expect(seed.id.rawValue == "future-1")
    }

    @Test func decodesCommandOutputDeltaWithoutDisplayText() throws {
        let json = """
        {
          "method": "item/commandExecution/outputDelta",
          "params": {
            "itemId": "cmd-1",
            "delta": "Build complete"
          }
        }
        """.data(using: .utf8)!

        let notification = try JSONDecoder().decode(AppServerWireReviewNotification.self, from: json)
        let events = notification.domainEvents()

        guard case .textDelta(let itemID, let kind, let family, let content, let delta) = try #require(events.first) else {
            Issue.record("expected text delta")
            return
        }
        #expect(itemID.rawValue == "cmd-1")
        #expect(kind == .commandExecution)
        #expect(family == .command)
        #expect(delta == "Build complete")
        if case .command(let command) = content {
            #expect(command.output.isEmpty)
        } else {
            Issue.record("expected command content")
        }
    }
}
