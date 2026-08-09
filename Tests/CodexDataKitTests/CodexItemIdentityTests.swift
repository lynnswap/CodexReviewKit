import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Testing

@Suite("Codex item identity")
@MainActor
struct CodexItemIdentityTests {
    @Test("message deltas use their required item identity")
    func messageDeltasUseRequiredItemIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-message-delta"))
        let turnID = CodexTurnID(rawValue: "turn-message-delta")

        _ = chat.apply(.turnStarted(turnID))
        _ = chat.apply(.messageDelta(
            CodexMessageDelta(text: "Hello", itemID: "message-live"),
            turnID: turnID
        ))
        let item = try #require(chat.items.first)
        _ = chat.apply(.messageDelta(
            CodexMessageDelta(text: " world", itemID: "message-live"),
            turnID: turnID
        ))

        #expect(chat.items.count == 1)
        #expect(chat.items.first === item)
        #expect(item.itemID == "message-live")
        #expect(item.message?.text == "Hello world")
        await runtime.close()
    }

    @Test("authoritative snapshots reuse the same message identity")
    func authoritativeSnapshotsReuseSameMessageIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-message-snapshot"))
        let turnID = CodexTurnID(rawValue: "turn-message-snapshot")

        _ = chat.apply(.turnStarted(turnID))
        _ = chat.apply(.messageDelta(
            CodexMessageDelta(text: "Final answer", itemID: "message-real"),
            turnID: turnID
        ))
        let liveItem = try #require(chat.items.first)
        let rawPayload = Data(#"{"id":"message-real","type":"agent_message"}"#.utf8)

        _ = chat.apply(.completed(CodexResponse(
            turnID: turnID,
            transcript: .init(items: [
                agentMessageItem(
                    id: "message-real",
                    text: "Final answer",
                    phase: .finalAnswer,
                    rawPayload: rawPayload
                ),
            ])
        )))

        let snapshotItem = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(snapshotItem === liveItem)
        #expect(snapshotItem.itemID == "message-real")
        #expect(snapshotItem.rawPayload == rawPayload)
        #expect(snapshotItem.message?.phase == .finalAnswer)
        await runtime.close()
    }

    @Test("equal message text does not replace distinct identities")
    func equalMessageTextDoesNotReplaceDistinctIdentities() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-distinct-messages"))
        let turnID = CodexTurnID(rawValue: "turn-distinct-messages")

        chat.apply(
            CodexThreadSnapshot(
                id: chat.id,
                turns: [
                    .init(
                        id: turnID,
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            agentMessageItem(id: "message-a", text: "Same text"),
                            agentMessageItem(id: "message-b", text: "Same text"),
                        ]
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )

        #expect(chat.items.map(\.itemID) == ["message-a", "message-b"])
        #expect(chat.items.map(\.text) == ["Same text", "Same text"])
        await runtime.close()
    }

    @Test("review marker identity retains raw ID and kind")
    func reviewMarkerIdentityRetainsRawIDAndKind() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-review-marker-identity"))
        let turnID = CodexTurnID(rawValue: "turn-review-marker-identity")

        chat.apply(
            CodexThreadSnapshot(
                id: chat.id,
                turns: [
                    .init(
                        id: turnID,
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            reviewMarkerItem(
                                id: "review-marker",
                                kind: .enteredReviewMode,
                                text: "entered"
                            ),
                            reviewMarkerItem(
                                id: "review-marker",
                                kind: .exitedReviewMode,
                                text: "exited"
                            ),
                            reviewMarkerItem(
                                id: "8f80d976-f70d-4d37-af93-f8ba57fb802f",
                                kind: .enteredReviewMode,
                                text: "entered again"
                            ),
                        ]
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )

        #expect(chat.items.count == 3)
        #expect(chat.items.map(\.kind) == [
            .enteredReviewMode,
            .exitedReviewMode,
            .enteredReviewMode,
        ])
        #expect(Set(chat.items.map(\.id)).count == 3)
        #expect(chat.items.map(\.itemID) == [
            "review-marker",
            "review-marker",
            "8f80d976-f70d-4d37-af93-f8ba57fb802f",
        ])
        #expect(chat.items.map(\.id.rawValue) == [
            "turn-review-marker-identity:enteredReviewMode:review-marker",
            "turn-review-marker-identity:exitedReviewMode:review-marker",
            "turn-review-marker-identity:enteredReviewMode:8f80d976-f70d-4d37-af93-f8ba57fb802f",
        ])
        let locators = chat.items.map {
            CodexChatItemLocator(
                id: $0.itemID,
                kind: $0.kind,
                turnID: turnID
            )
        }
        #expect(Set(locators).count == 3)
        await runtime.close()
    }

    private func agentMessageItem(
        id: String,
        text: String,
        phase: CodexMessagePhase? = nil,
        rawPayload: Data? = nil
    ) -> CodexThreadItem {
        CodexThreadItem(
            id: id,
            kind: .agentMessage,
            content: .message(.init(
                id: id,
                role: .assistant,
                phase: phase,
                text: text
            )),
            rawPayload: rawPayload
        )
    }

    private func reviewMarkerItem(
        id: String,
        kind: CodexThreadItem.Kind,
        text: String
    ) -> CodexThreadItem {
        CodexThreadItem(
            id: id,
            kind: kind,
            content: .log(text)
        )
    }
}
