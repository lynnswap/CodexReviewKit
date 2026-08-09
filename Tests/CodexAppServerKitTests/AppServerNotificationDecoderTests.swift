import Foundation
import Testing

@testable import CodexAppServerKit
import CodexAppServerKitTesting

@Suite("AppServerNotificationDecoder")
struct AppServerNotificationDecoderTests {
    @Test func currentV2MapperPreservesCanonicalFileChangePathsAndDiffs() throws {
        let fixture = try CodexAppServerTestItem.fileChange(
            id: "file-change-1",
            changes: [
                .init(
                    path: "Sources/First.swift",
                    kind: .update(movePath: "Sources/Renamed.swift"),
                    diff: "@@ -1 +1 @@\n-old\n+new"
                ),
                .init(
                    path: "Sources/Second.swift",
                    kind: .add,
                    diff: "@@ -0,0 +1 @@\n+second"
                ),
            ],
            status: .completed
        )
        let wireData = try JSONEncoder().encode(fixture.wireValue)
        let wireValue = try JSONDecoder().decode(AppServerJSONValue.self, from: wireData)

        let mapped = try #require(AppServerThreadItemMapping.threadItem(from: wireValue))

        #expect(mapped.id == fixture.domainProjection.id)
        #expect(mapped.kind == fixture.domainProjection.kind)
        #expect(mapped.content == fixture.domainProjection.content)
    }

    @Test func currentV2MapperDoesNotSynthesizeOutputForEmptyFileChanges() throws {
        let mapped = try #require(AppServerThreadItemMapping.threadItem(from: .object([
            "id": .string("file-change-empty"),
            "type": .string("fileChange"),
            "changes": .array([]),
            "status": .string("inProgress"),
        ])))

        guard case .fileChange(let fileChange) = mapped.content else {
            Issue.record("Expected a file-change item.")
            return
        }
        #expect(fileChange.path == nil)
        #expect(fileChange.output == nil)
        #expect(fileChange.status == .inProgress)
    }

    @Test func currentV2MapperRejectsFileChangeWithoutRequiredChanges() {
        #expect(AppServerThreadItemMapping.threadItem(from: .object([
            "id": .string("file-change-missing"),
            "type": .string("fileChange"),
            "status": .string("inProgress"),
        ])) == nil)
    }

    @Test func currentV2MapperAssignsReviewRolloutCompanionMetadataOnlyToFixedAgentItem() throws {
        let reviewAssistant = try #require(AppServerThreadItemMapping.threadItem(from: .object([
            "id": .string("review_rollout_assistant"),
            "type": .string("agentMessage"),
            "text": .string("review output"),
        ])))
        let sameIDWrongKind = try #require(AppServerThreadItemMapping.threadItem(from: .object([
            "id": .string("review_rollout_assistant"),
            "type": .string("plan"),
            "text": .string("plan"),
        ])))
        let ordinaryAssistant = try #require(AppServerThreadItemMapping.threadItem(from: .object([
            "id": .string("assistant-1"),
            "type": .string("agentMessage"),
            "text": .string("answer"),
        ])))

        #expect(reviewAssistant.origin == .reviewRolloutAssistant)
        #expect(reviewAssistant.semanticRelation == .companionOf(.exitedReviewMode))
        #expect(sameIDWrongKind.origin == .currentV2Item)
        #expect(sameIDWrongKind.semanticRelation == nil)
        #expect(ordinaryAssistant.origin == .currentV2Item)
        #expect(ordinaryAssistant.semanticRelation == nil)
    }

    @Test func pinnedNotificationInventoryHasOneDispositionPerMethod() {
        let route: Set<String> = [
            "error",
            "thread/started",
            "thread/status/changed",
            "thread/archived",
            "thread/deleted",
            "thread/unarchived",
            "thread/closed",
            "thread/name/updated",
            "thread/tokenUsage/updated",
            "turn/started",
            "turn/completed",
            "turn/diff/updated",
            "turn/plan/updated",
            "item/started",
            "item/completed",
            "item/agentMessage/delta",
            "item/plan/delta",
            "item/commandExecution/outputDelta",
            "item/fileChange/patchUpdated",
            "serverRequest/resolved",
            "item/mcpToolCall/progress",
            "account/updated",
            "account/rateLimits/updated",
            "account/login/completed",
            "item/reasoning/summaryTextDelta",
            "item/reasoning/summaryPartAdded",
            "item/reasoning/textDelta",
        ]
        let diagnostic: Set<String> = [
            "warning",
            "guardianWarning",
            "deprecationNotice",
            "configWarning",
            "model/rerouted",
            "model/verification",
            "turn/moderationMetadata",
            "model/safetyBuffering/updated",
            "windows/worldWritableWarning",
            "windowsSandbox/setupCompleted",
        ]
        let explicitIgnore: Set<String> = [
            "skills/changed",
            "thread/goal/updated",
            "thread/goal/cleared",
            "thread/settings/updated",
            "hook/started",
            "hook/completed",
            "item/autoApprovalReview/started",
            "item/autoApprovalReview/completed",
            "rawResponseItem/completed",
            "command/exec/outputDelta",
            "process/outputDelta",
            "process/exited",
            "item/commandExecution/terminalInteraction",
            "item/fileChange/outputDelta",
            "mcpServer/oauthLogin/completed",
            "mcpServer/startupStatus/updated",
            "app/list/updated",
            "remoteControl/status/changed",
            "externalAgentConfig/import/progress",
            "externalAgentConfig/import/completed",
            "fs/changed",
            "thread/compacted",
            "fuzzyFileSearch/sessionUpdated",
            "fuzzyFileSearch/sessionCompleted",
            "thread/realtime/started",
            "thread/realtime/itemAdded",
            "thread/realtime/transcript/delta",
            "thread/realtime/transcript/done",
            "thread/realtime/outputAudio/delta",
            "thread/realtime/sdp",
            "thread/realtime/error",
            "thread/realtime/closed",
        ]

        let methods = AppServerNotificationDecoder.Method.allCases
        #expect(methods.count == 69)
        #expect(Set(methods.filter { $0.disposition == .route }.map(\.rawValue)) == route)
        #expect(Set(methods.filter { $0.disposition == .diagnostic }.map(\.rawValue)) == diagnostic)
        #expect(Set(methods.filter { $0.disposition == .explicitIgnore }.map(\.rawValue))
            == explicitIgnore)
        #expect(route.isDisjoint(with: diagnostic))
        #expect(route.isDisjoint(with: explicitIgnore))
        #expect(diagnostic.isDisjoint(with: explicitIgnore))
    }

    @Test func requiredFieldsAndClosedStatusesFailAsMalformedNotifications() throws {
        let decoder = AppServerNotificationDecoder()

        try expectMalformed(method: "thread/status/changed") {
            try decoder.decode(notification(
                method: "thread/status/changed",
                json: #"{"threadId":"thread-1"}"#
            ))
        }
        try expectMalformed(method: "item/started") {
            try decoder.decode(notification(
                method: "item/started",
                json: #"{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"id":"command-1","type":"commandExecution","command":"swift test","commandActions":[],"cwd":"/workspace","status":"pending"}}"#
            ))
        }
        try expectMalformed(method: "account/updated") {
            try decoder.decode(notification(
                method: "account/updated",
                json: #"{"authMode":"chatgpt","planType":"ultra"}"#
            ))
        }
        try expectMalformed(method: "turn/plan/updated") {
            try decoder.decode(notification(
                method: "turn/plan/updated",
                json: #"{"threadId":"thread-1","turnId":"turn-1","plan":[{"step":"Ship","status":"running"}]}"#
            ))
        }
        try expectMalformed(method: "hook/started") {
            try decoder.decode(notification(
                method: "hook/started",
                json: Self.hookFixture(status: "pending")
            ))
        }
        try expectMalformed(method: "rawResponseItem/completed") {
            try decoder.decode(notification(
                method: "rawResponseItem/completed",
                json: #"{"threadId":"thread-1","turnId":"turn-1","item":{"type":"local_shell_call","action":{},"status":"running"}}"#
            ))
        }
        try expectMalformed(method: "item/fileChange/patchUpdated") {
            try decoder.decode(notification(
                method: "item/fileChange/patchUpdated",
                json: #"{"threadId":"thread-1","turnId":"turn-1","itemId":"file-1","changes":[{"path":"File.swift","kind":{"type":"update"}}]}"#
            ))
        }
        try expectMalformed(method: "item/agentMessage/delta") {
            try decoder.decode(notification(
                method: "item/agentMessage/delta",
                json: #"{"threadId":"thread-1","turnId":"turn-1","delta":"missing"}"#
            ))
        }
        try expectMalformed(method: "item/agentMessage/delta") {
            try decoder.decode(notification(
                method: "item/agentMessage/delta",
                json: #"{"threadId":"thread-1","turnId":"turn-1","itemId":"","delta":"empty"}"#
            ))
        }
        try expectMalformed(method: "item/agentMessage/delta") {
            try decoder.decode(notification(
                method: "item/agentMessage/delta",
                json: #"{"threadId":"thread-1","turnId":"turn-1","itemId":" \n\t ","delta":"blank"}"#
            ))
        }
    }

    @Test func extensibleWireValuesReachTheirDomainRepresentations() throws {
        let decoder = AppServerNotificationDecoder()

        for status in ["running", "started"] {
            let decoded = try decoder.decode(notification(
                method: "turn/started",
                json: #"{"threadId":"thread-1","turn":{"id":"turn-1","status":"\#(status)","items":[]}}"#
            ))
            #expect(decoded.payload == .turnStarted("turn-1"))
        }

        let threadStatus = try decoder.decode(notification(
            method: "thread/status/changed",
            json: #"{"threadId":"thread-1","status":{"type":"paused"}}"#
        ))
        #expect(threadStatus.payload == .threadStatus(.unknown(rawValue: "paused")))

        let futureItem = try decoder.decode(notification(
            method: "item/started",
            json: #"{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1000,"item":{"id":"future-1","type":"futureItem","text":"payload"}}"#
        ))
        guard case .item(.started(let item)) = futureItem.payload else {
            Issue.record("Expected a future item start mutation.")
            return
        }
        #expect(item.kind == .unknown("futureItem"))
        guard case .unknown(let rawItem) = item.content else {
            Issue.record("Expected the future item payload to remain available.")
            return
        }
        #expect(rawItem.rawType == "futureItem")
        #expect(rawItem.text == "payload")
        #expect(rawItem.payload != nil)
    }

    @Test func currentItemAndTerminalPayloadsKeepTheirTypedContracts() throws {
        let decoder = AppServerNotificationDecoder()
        let started = try decoder.decode(notification(
            method: "item/started",
            json: #"{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1000,"item":{"id":"command-1","type":"commandExecution","command":"swift test","commandActions":[],"cwd":"/workspace","status":"inProgress"}}"#
        ))
        guard case .item(.started(let item)) = started.payload else {
            Issue.record("Expected a typed item start mutation.")
            return
        }
        #expect(started.context == .init(threadID: "thread-1", turnID: "turn-1"))
        #expect(item.id == "command-1")

        let error = try decoder.decode(notification(
            method: "error",
            json: #"{"threadId":"thread-1","turnId":"turn-1","error":{"message":"retrying","codexErrorInfo":"serverOverloaded","additionalDetails":"retry scheduled"},"willRetry":true}"#
        ))
        guard case .item(.turnDiagnostic(let diagnostic)) = error.payload else {
            Issue.record("Expected a typed turn diagnostic mutation.")
            return
        }
        #expect(error.context == .init(threadID: "thread-1", turnID: "turn-1"))
        #expect(diagnostic == .init(
            error: .init(
                message: "retrying",
                info: .serverOverloaded,
                additionalDetails: "retry scheduled"
            ),
            willRetry: true
        ))

        let futureTerminal = try decoder.decode(notification(
            method: "turn/completed",
            json: #"{"threadId":"thread-1","turn":{"id":"turn-1","status":"futureStatus","items":[]}}"#
        ))
        guard case .turnCompleted(let turn) = futureTerminal.payload else {
            Issue.record("Expected a typed terminal turn.")
            return
        }
        #expect(turn.status == "futureStatus")
    }

    @Test func historicalAliasesAreUnknownConnectionDiagnosticsAndLegacyFileDeltaIsValidatedIgnore() throws {
        let decoder = AppServerNotificationDecoder()
        for method in ["turn/failed", "turn/cancelled", "item/updated", "agent/message"] {
            let decoded = try decoder.decode(notification(method: method, json: #"{}"#))
            #expect(decoded.method == nil)
            #expect(decoded.methodName == method)
            #expect(decoded.disposition == .diagnostic)
            #expect(decoded.payload == .connectionDiagnostic(.unknown(.init(
                method: method,
                params: Data(#"{}"#.utf8)
            ))))
        }

        let legacy = try decoder.decode(notification(
            method: "item/fileChange/outputDelta",
            json: #"{"threadId":"thread-1","turnId":"turn-1","itemId":"file-1","delta":"patch"}"#
        ))
        #expect(legacy.method == .itemFileChangeOutputDelta)
        #expect(legacy.disposition == .explicitIgnore)
        #expect(legacy.payload == .ignored)

        try expectMalformed(method: "item/fileChange/outputDelta") {
            try decoder.decode(notification(
                method: "item/fileChange/outputDelta",
                json: #"{"threadId":"thread-1","turnId":"turn-1","itemId":"file-1"}"#
            ))
        }
    }

    @Test func everyExplicitIgnoreHasACanonicalPayloadFixture() throws {
        let fixtures: [AppServerNotificationDecoder.Method: String] = [
            .skillsChanged: #"{}"#,
            .threadGoalUpdated: #"{"threadId":"thread-1","goal":{"createdAt":1,"objective":"Ship","status":"active","threadId":"thread-1","timeUsedSeconds":0,"tokensUsed":0,"updatedAt":1}}"#,
            .threadGoalCleared: #"{"threadId":"thread-1"}"#,
            .threadSettingsUpdated: #"{"threadId":"thread-1","threadSettings":{"approvalPolicy":"never","approvalsReviewer":"user","collaborationMode":{"mode":"default","settings":{"model":"gpt-5"}},"cwd":"/workspace","model":"gpt-5","modelProvider":"openai","sandboxPolicy":{"type":"dangerFullAccess"}}}"#,
            .hookStarted: Self.hookFixture(status: "running"),
            .hookCompleted: Self.hookFixture(status: "completed"),
            .itemAutoApprovalReviewStarted: #"{"threadId":"thread-1","turnId":"turn-1","action":{"type":"command","command":"ls","cwd":"/workspace","source":"shell"},"review":{"status":"inProgress"},"reviewId":"review-1","startedAtMs":1}"#,
            .itemAutoApprovalReviewCompleted: #"{"threadId":"thread-1","turnId":"turn-1","action":{"type":"command","command":"ls","cwd":"/workspace","source":"shell"},"review":{"status":"approved"},"reviewId":"review-1","startedAtMs":1,"completedAtMs":2,"decisionSource":"agent"}"#,
            .rawResponseItemCompleted: #"{"threadId":"thread-1","turnId":"turn-1","item":{"type":"other"}}"#,
            .commandExecOutputDelta: #"{"capReached":false,"deltaBase64":"","processId":"process-1","stream":"stdout"}"#,
            .processOutputDelta: #"{"capReached":false,"deltaBase64":"","processHandle":"process-1","stream":"stderr"}"#,
            .processExited: #"{"exitCode":0,"processHandle":"process-1","stderr":"","stderrCapReached":false,"stdout":"","stdoutCapReached":false}"#,
            .itemCommandExecutionTerminalInteraction: #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","processId":"process-1","stdin":"input"}"#,
            .itemFileChangeOutputDelta: #"{"threadId":"thread-1","turnId":"turn-1","itemId":"file-1","delta":"patch"}"#,
            .mcpServerOAuthLoginCompleted: #"{"name":"server","success":true}"#,
            .mcpServerStartupStatusUpdated: #"{"name":"server","status":"ready"}"#,
            .appListUpdated: #"{"data":[]}"#,
            .remoteControlStatusChanged: #"{"installationId":"installation-1","serverName":"server","status":"connected"}"#,
            .externalAgentConfigImportProgress: #"{"importId":"import-1","itemTypeResults":[]}"#,
            .externalAgentConfigImportCompleted: #"{"importId":"import-1","itemTypeResults":[]}"#,
            .fsChanged: #"{"changedPaths":["/workspace/File.swift"],"watchId":"watch-1"}"#,
            .threadCompacted: #"{"threadId":"thread-1","turnId":"turn-1"}"#,
            .fuzzyFileSearchSessionUpdated: #"{"files":[],"query":"File","sessionId":"search-1"}"#,
            .fuzzyFileSearchSessionCompleted: #"{"sessionId":"search-1"}"#,
            .threadRealtimeStarted: #"{"threadId":"thread-1","version":"v1"}"#,
            .threadRealtimeItemAdded: #"{"threadId":"thread-1","item":{}}"#,
            .threadRealtimeTranscriptDelta: #"{"threadId":"thread-1","delta":"hello","role":"assistant"}"#,
            .threadRealtimeTranscriptDone: #"{"threadId":"thread-1","role":"assistant","text":"hello"}"#,
            .threadRealtimeOutputAudioDelta: #"{"threadId":"thread-1","audio":"AA=="}"#,
            .threadRealtimeSDP: #"{"threadId":"thread-1","sdp":"offer"}"#,
            .threadRealtimeError: #"{"threadId":"thread-1","message":"failed"}"#,
            .threadRealtimeClosed: #"{"threadId":"thread-1"}"#,
        ]
        let ignoredMethods = Set(AppServerNotificationDecoder.Method.allCases.filter {
            $0.disposition == .explicitIgnore
        })
        #expect(Set(fixtures.keys) == ignoredMethods)

        let decoder = AppServerNotificationDecoder()
        for method in ignoredMethods {
            let json = try #require(fixtures[method])
            let decoded = try decoder.decode(notification(method: method.rawValue, json: json))
            #expect(decoded.method == method)
            #expect(decoded.disposition == .explicitIgnore)
            #expect(decoded.payload == .ignored)
        }
    }

    @Test func loginCompletionRemainsTypedForAccountEventHubMigration() throws {
        let decoded = try AppServerNotificationDecoder().decode(notification(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        ))
        guard case .account(.loginCompleted(let completion)) = decoded.payload else {
            Issue.record("Expected a typed login completion.")
            return
        }
        #expect(completion.loginID?.rawValue == "login-1")
        #expect(completion.success)
    }

    private static func hookFixture(status: String) -> String {
        #"{"threadId":"thread-1","turnId":"turn-1","run":{"displayOrder":0,"entries":[],"eventName":"preToolUse","executionMode":"sync","handlerType":"command","id":"hook-1","scope":"turn","sourcePath":"/workspace/hook","startedAt":1,"status":"\#(status)"}}"#
    }
}

@Suite("AccountEventHub")
struct AccountEventHubTests {
    @Test func sparseRateLimitUpdateMergesIntoLastFullReadSnapshot() async throws {
        let hub = AccountEventHub()
        await hub.replaceRateLimits(with: .init(rateLimits: .init(
            limitID: "codex",
            primary: .init(usedPercent: 10, windowDurationMins: 15),
            secondary: .init(usedPercent: 20, windowDurationMins: 10_080),
            planType: "plus"
        )))
        let events = await hub.events()
        #expect(await hub.subscriberCountForTesting == 1)

        await hub.apply(.rateLimitsUpdated(.init(
            limitID: "codex",
            primary: .init(usedPercent: 30, windowDurationMins: 15)
        )))
        await hub.apply(.rateLimitsUpdated(.init(
            limitID: "codex",
            primary: .init(usedPercent: 40, windowDurationMins: 15)
        )))
        await hub.apply(.updated(.init(authMode: .chatGPT, planType: .plus)))
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .rateLimitsUpdated(.init(
            planType: "plus",
            windows: [
                .init(windowDurationMinutes: 15, usedPercent: 40),
                .init(windowDurationMinutes: 10_080, usedPercent: 20),
            ]
        )))
        #expect(try await iterator.next() == .accountUpdated)

        await events.cancel()
        #expect(await hub.subscriberCountForTesting == 0)
        await events.cancel()
        #expect(await hub.subscriberCountForTesting == 0)
    }

    @Test func taskCancellationSynchronouslyReleasesWaitingSubscription() async throws {
        let hub = AccountEventHub()
        let events = await hub.events()
        let waiter = Task { () throws -> CodexAccountEvent? in
            var iterator = events.makeAsyncIterator()
            return try await iterator.next()
        }
        await events.waitUntilNextSuspendsForTesting()
        waiter.cancel()
        #expect(try await waiter.value == nil)
        #expect(await hub.subscriberCountForTesting == 0)
    }

    @Test func nullableSparseFieldsDoNotClearPreviouslyObservedValues() {
        let base = AppServerAPI.Account.RateLimits.Snapshot(
            limitID: "codex",
            primary: .init(
                usedPercent: 10,
                windowDurationMins: 15,
                resetsAt: 1_700_000_000
            ),
            secondary: .init(usedPercent: 20, windowDurationMins: 10_080),
            planType: "plus"
        )
        let merged = base.merging(.init(
            limitID: "codex",
            primary: .init(usedPercent: 40, windowDurationMins: 15)
        ))
        #expect(merged.limitID == "codex")
        #expect(merged.primary?.usedPercent == 40)
        #expect(merged.primary?.windowDurationMins == 15)
        #expect(merged.primary?.resetsAt == 1_700_000_000)
        #expect(merged.secondary == base.secondary)
        #expect(merged.planType == "plus")
    }

    @Test func loginReplaysCompletionAndAccountUpdateReceivedBeforeBinding() async throws {
        let registry = LoginRegistry()
        let state = try await registry.reserve(
            readinessTimeout: nil,
            cancel: { _, _ in .cancelled },
            closeConnection: {}
        )
        await registry.apply(.init(loginID: "login-new", success: true))
        await registry.applyAccountUpdate(.init(authMode: .chatGPT, planType: .plus))
        let handle = try await registry.bind(
            state,
            id: "login-new",
            authenticationURL: try #require(URL(string: "https://example.com/login"))
        )
        #expect(try await handle.result() == .succeeded)
    }
}

private func notification(method: String, json: String) -> JSONRPC.Notification {
    .init(method: method, params: Data(json.utf8))
}

private func expectMalformed(
    method: String,
    operation: () throws -> AppServerNotificationDecoder.DecodedNotification
) throws {
    do {
        _ = try operation()
        Issue.record("Expected malformed notification for \(method).")
    } catch let CodexAppServerError.malformedNotification(failure) {
        #expect(failure.method == method)
        #expect(failure.rawData != nil)
    }
}
