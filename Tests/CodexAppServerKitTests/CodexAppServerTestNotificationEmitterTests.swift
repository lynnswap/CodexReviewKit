import CodexAppServerKit
import CodexAppServerKitTesting
import Testing

@Suite("CodexAppServerTestNotificationEmitter")
struct CodexAppServerTestNotificationEmitterTests {
    @Test(arguments: ["", " \n\t "])
    func agentMessageDeltaRejectsInvalidItemIdentity(_ itemID: String) async throws {
        let runtime = try await CodexAppServerTestRuntime.start()

        await #expect(throws: CodexAppServerTestError.invalidFixture(
            "thread, turn, and item ids must not be empty or whitespace"
        )) {
            try await runtime.notificationEmitter.emitAgentMessageDelta(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: itemID,
                delta: "invalid"
            )
        }

        await runtime.close()
    }
}
