import Foundation
import CodexKit
@_spi(Testing) import CodexReviewKit

@_spi(PreviewSupport)
@MainActor
public final class ReviewMonitorPreviewContentSource {
    public let store: CodexReviewStore
    public let codexModelSource: ReviewMonitorCodexModelSource
    let runtime: ReviewMonitorPreviewAppServerRuntime

    init(
        store: CodexReviewStore,
        runtime: ReviewMonitorPreviewAppServerRuntime
    ) {
        self.store = store
        self.runtime = runtime
        self.codexModelSource = runtime.modelSource
    }

    var initialSelection: ReviewMonitorSelection? {
        runtime.initialSelection
    }

    func start() {
        runtime.start()
    }

    func startStreaming(interval: Duration) {
        runtime.startStreaming(interval: interval)
    }

    @discardableResult
    func appendPreviewChatLogStreamTick(
        after tick: Int = 0,
        emitsNotifications: Bool = false
    ) async -> Int {
        await runtime.appendPreviewStreamTick(
            after: tick,
            emitsNotifications: emitsNotifications
        )
    }

    func snapshotForTesting(chatID: CodexThreadID) -> CodexChatSnapshot? {
        runtime.snapshotForTesting(chatID: chatID)
    }
}

@_spi(PreviewSupport)
@MainActor
public enum ReviewMonitorPreviewContent {
    fileprivate enum PreviewChatLifecycle {
        case queued
        case running
        case succeeded
        case failed
        case cancelled
    }

    private struct PreviewChatDefinition {
        let lifecycle: PreviewChatLifecycle
        let targetSummary: String
        let summary: String
        let initialMessage: String
        let model: String
        let startedOffset: TimeInterval?
        let endedOffset: TimeInterval?
    }

    private struct PreviewChatFixture {
        let id: String
        let chatID: CodexThreadID
        let turnID: CodexTurnID
        let cwd: String
        let targetSummary: String
        let summary: String
        let initialMessage: String
        let model: String
        let lifecycle: PreviewChatLifecycle
        let startedAt: Date?
        let endedAt: Date?
        let chatItems: [PreviewChatLogItemTemplate]
    }

    private enum PreviewReasoningStyle {
        case raw
        case summary
    }

    private struct PreviewStreamTemplate {
        let itemName: String?
        let kind: CodexThreadItem.Kind
        let content: CodexThreadItem.Content
        let mode: PreviewStreamMode
        let deltaText: String?
        let chunkByWord: Bool
        let delayBeforeFrameCount: Int
        let chunkIntervalFrameCount: Int

        init(
            itemName: String? = nil,
            kind: CodexThreadItem.Kind,
            content: CodexThreadItem.Content,
            mode: PreviewStreamMode = .complete,
            deltaText: String? = nil,
            chunkByWord: Bool = false,
            delayBeforeFrameCount: Int,
            chunkIntervalFrameCount: Int = 1
        ) {
            self.itemName = itemName
            self.kind = kind
            self.content = content
            self.mode = mode
            self.deltaText = deltaText
            self.chunkByWord = chunkByWord
            self.delayBeforeFrameCount = delayBeforeFrameCount
            self.chunkIntervalFrameCount = chunkIntervalFrameCount
        }
    }

    package enum PreviewStreamMode {
        case update
        case complete
        case textDelta
    }

    private struct PreviewChatLogItemTemplate {
        let itemName: String
        let kind: CodexThreadItem.Kind
        let content: CodexThreadItem.Content

        init(
            itemName: String,
            kind: CodexThreadItem.Kind,
            content: CodexThreadItem.Content
        ) {
            self.itemName = itemName
            self.kind = kind
            self.content = content
        }

        func itemSnapshot(id: String, turnID: CodexTurnID) -> CodexChatItemSnapshot {
            CodexChatItemSnapshot(
                id: id,
                turnID: turnID,
                kind: kind,
                content: content
            )
        }
    }

    package struct PreviewChatLogStreamStep {
        let itemName: String
        let kind: CodexThreadItem.Kind
        let content: CodexThreadItem.Content
        let mode: PreviewStreamMode
        let deltaText: String?

        func itemSnapshot(id: String, turnID: CodexTurnID?) -> CodexChatItemSnapshot {
            CodexChatItemSnapshot(
                id: id,
                turnID: turnID,
                kind: kind,
                content: content
            )
        }
    }

    package struct PreviewStreamFrame {
        let step: PreviewChatLogStreamStep
        let cycle: Int
    }

    private struct PreviewSidebarContent {
        var chatLogFixtures: [ReviewMonitorPreviewChatLogFixture]
        var reviewRuns: [ReviewRunRecord]
    }

    @_spi(PreviewSupport)
    public static func makeStore() -> CodexReviewStore {
        makeStore(previewContent: makeSidebarContent())
    }

    @_spi(PreviewSupport)
    public static func makeContentSource() -> ReviewMonitorPreviewContentSource {
        let previewContent = makeSidebarContent()
        let store = makeStore(previewContent: previewContent)
        let previewRuntime = ReviewMonitorPreviewAppServerRuntime(
            fixtures: previewContent.chatLogFixtures
        )
        return ReviewMonitorPreviewContentSource(
            store: store,
            runtime: previewRuntime
        )
    }

    private static func makeStore(previewContent: PreviewSidebarContent) -> CodexReviewStore {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: makePreviewSettingsSnapshot())
        )
        let accounts = makePreviewAccounts()
        store.loadForTesting(
            serverState: .running,
            account: accounts.first,
            persistedAccounts: accounts,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            reviewRuns: previewContent.reviewRuns
        )
        return store
    }

    @_spi(PreviewSupport)
    public static func makeCommandOutputStore() -> CodexReviewStore {
        makeCommandOutputContentSource().store
    }

    @_spi(PreviewSupport)
    public static func makeCommandOutputContentSource() -> ReviewMonitorPreviewContentSource {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: makePreviewSettingsSnapshot())
        )
        let accounts = makePreviewAccounts()
        let cwd = "/path/to/workspace-alpha"
        let now = Date()
        let chatItems = makeCommandOutputPreviewChatLogItems()
        let chatID = CodexThreadID(rawValue: "preview-command-output-panel")
        let turnID = CodexTurnID(rawValue: "preview-command-output-turn")
        let chatFixture = PreviewChatFixture(
            id: "preview-command-output-panel",
            chatID: chatID,
            turnID: turnID,
            cwd: cwd,
            targetSummary: "Command output panel",
            summary: "A command output block is collapsed by default.",
            initialMessage: "Opened command output should stay bounded to a short embedded scroll view.",
            model: "gpt-5.4",
            lifecycle: .running,
            startedAt: now.addingTimeInterval(-135),
            endedAt: nil,
            chatItems: chatItems
        )
        store.loadForTesting(
            serverState: .running,
            account: accounts.first,
            persistedAccounts: accounts,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            reviewRuns: [
                makeReviewRunRecord(
                    for: chatFixture,
                    runIndex: 0
                )
            ]
        )
        let fixture = makeChatLogFixture(
            for: chatFixture
        )
        return ReviewMonitorPreviewContentSource(
            store: store,
            runtime: ReviewMonitorPreviewAppServerRuntime(fixtures: [fixture])
        )
    }

    package static func streamFrame(
        forRunningChatAt runningChatIndex: Int,
        tick: Int
    ) -> PreviewStreamFrame? {
        guard previewChatLogStreamSchedule.isEmpty == false else {
            return nil
        }
        let chatTick = tick - runningChatIndex * previewChatTickOffset
        guard chatTick > 0 else {
            return nil
        }

        let offset = (chatTick - 1) % previewChatLogStreamSchedule.count
        guard let step = previewChatLogStreamSchedule[offset] else {
            return nil
        }
        return PreviewStreamFrame(
            step: step,
            cycle: (chatTick - 1) / previewChatLogStreamSchedule.count
        )
    }

    package static func previewChatLogItemID(
        itemName: String,
        streamID: String,
        cycle: Int
    ) -> String {
        "preview-\(itemName)-\(streamID)-\(cycle)"
    }

    private static func previewTurnID(_ tick: Int) -> String {
        if tick < 10 {
            return "preview-turn-00\(tick)"
        }
        if tick < 100 {
            return "preview-turn-0\(tick)"
        }
        return "preview-turn-\(tick)"
    }

    private static func chatLogStreamSchedule(from templates: [PreviewStreamTemplate]) -> [PreviewChatLogStreamStep?] {
        var schedule: [PreviewChatLogStreamStep?] = []
        for (templateIndex, template) in templates.enumerated() {
            let delay = schedule.isEmpty ? 1 : max(1, template.delayBeforeFrameCount)
            if delay > 1 {
                schedule.append(contentsOf: Array(repeating: nil, count: delay - 1))
            }
            let itemName = template.itemName ?? "stream-\(templateIndex)"
            let streamText = template.deltaText ?? ""
            let chunks = template.chunkByWord ? wordChunks(in: streamText) : [streamText]
            for (index, chunk) in chunks.enumerated() {
                if index > 0 && template.chunkIntervalFrameCount > 1 {
                    schedule.append(contentsOf: Array(repeating: nil, count: template.chunkIntervalFrameCount - 1))
                }
                schedule.append(
                    PreviewChatLogStreamStep(
                        itemName: itemName,
                        kind: template.kind,
                        content: template.content,
                        mode: template.mode,
                        deltaText: template.mode == .textDelta ? chunk : template.deltaText
                    ))
            }
        }
        return schedule
    }

    private static func wordChunks(in text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.isEmpty == false else {
            return [text]
        }
        return words.enumerated().map { offset, word in
            if offset == words.count - 1 {
                return word
            }
            return word + " "
        }
    }

    private static let interItemDelayFrameCount = 39
    private static let commandCompletionDelayFrameCount = 60
    private static let compactionCompletionDelayFrameCount = 15
    private static let previewChatTickOffset = 21

    private static let previewStreamTemplates: [PreviewStreamTemplate] = [
        .init(
            kind: CodexThreadItem.Kind(rawValue: "event"),
            content: .diagnostic("Turn started: \(previewTurnID(1))"),
            delayBeforeFrameCount: 1
        ),
        .init(
            itemName: "plan",
            kind: .plan,
            content: .plan(
                """
                        [completed] Inspect ReviewMonitor log rendering
                        [in_progress] Preserve active find UI while streaming
                        [pending] Run focused UI tests
                        """),
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-search-test",
            kind: .commandExecution,
            content: .command(
                .init(
                    command:
                        "/bin/zsh -lc \"rg -n 'ReviewMonitorLog' Sources/ReviewUI && swift test --filter ReviewUI\"",
                    status: .running
                )),
            mode: .update,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-search-test",
            kind: .commandExecution,
            content: .command(
                .init(
                    command: "",
                    output: """
                        Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift:42: private let logDocumentView = ReviewMonitorLogDocumentView()
                        Sources/ReviewUI/Detail/ReviewMonitorLogDocumentView.swift:20: final class ReviewMonitorLogDocumentView
                        Test Suite 'ReviewUITests' passed.
                        """,
                    exitCode: 0,
                    status: .completed
                )),
            delayBeforeFrameCount: commandCompletionDelayFrameCount
        ),
        .init(
            kind: .mcpToolCall,
            content: .toolCall(
                .init(
                    result: "MCP codex_review.review_read started.",
                    status: .running
                )),
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "reasoning-summary",
            kind: .reasoning,
            content: .reasoning(.init(summary: "")),
            mode: .textDelta,
            deltaText:
                "Checking whether append-only log updates are notifying NSTextFinder while an incremental search is active.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-open-log-scroll",
            kind: .commandExecution,
            content: .command(
                .init(
                    command:
                        "/bin/zsh -lc \"sed -n '1,240p' Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift\"",
                    status: .running
                )),
            mode: .update,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-open-log-scroll",
            kind: .commandExecution,
            content: .command(
                .init(
                    command: "",
                    output: """
                        import AppKit
                        import ObjectiveC.runtime
                        import CodexReviewKit

                        @MainActor
                        final class ReviewMonitorLogScrollView: NSScrollView {
                            private let logDocumentView = ReviewMonitorLogDocumentView()
                        """,
                    exitCode: 0,
                    status: .completed
                )),
            delayBeforeFrameCount: commandCompletionDelayFrameCount
        ),
        .init(
            itemName: "context-compaction",
            kind: .contextCompaction,
            content: .contextCompaction("Automatically compacting context"),
            mode: .update,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "context-compaction",
            kind: .contextCompaction,
            content: .contextCompaction("Context automatically compacted"),
            delayBeforeFrameCount: compactionCompletionDelayFrameCount
        ),
        .init(
            kind: .mcpToolCall,
            content: .toolCall(
                .init(
                    result: "File changes updated.",
                    status: .completed
                )),
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "raw-reasoning",
            kind: .reasoning,
            content: .reasoning(.init(content: "")),
            mode: .textDelta,
            deltaText:
                "Need to avoid refreshing the finder client string until the user closes or clears the find bar. Appended text can wait for the next search session.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "raw-reasoning-follow-up",
            kind: .reasoning,
            content: .reasoning(.init(content: "")),
            mode: .textDelta,
            deltaText:
                "I found the log update path and am keeping the current find session stable while new output streams in.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "agent-message-summary",
            kind: .agentMessage,
            content: .message(
                .init(
                    id: "agent-message-summary",
                    role: .assistant,
                    text:
                        "The preview stream now mixes commands, tool events, reasoning summaries, and visible assistant output instead of one repeated message kind.\n",
                )),
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
    ]

    private static let previewChatLogStreamSchedule = chatLogStreamSchedule(from: previewStreamTemplates)

    private static func makeCommandOutputPreviewChatLogItems() -> [PreviewChatLogItemTemplate] {
        let output = """
            Command line invocation:
                /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj -scheme CodexReviewMonitor

            Resolve Package Graph

            Resolved source packages:
                ObservationBridge: /Users/kn/Dev/ObservationBridge
                CodexReviewKit: /Users/kn/Dev/CodexReviewKit

            Test Suite 'Selected tests' started.
            Test Case '-[ReviewUITests commandOutputRendersCollapsedTextKitPanel]' passed (0.142 seconds).
            Test Suite 'Selected tests' passed.
            """
        return [
            diagnosticItem(
                "command-output-event",
                kind: CodexThreadItem.Kind(rawValue: "event"),
                message: "Turn started: preview-command-output-panel"
            ),
            messageItem(
                "command-output-intro",
                text: """
                    Checking the command output rendering path.

                    - Keep the transcript readable.
                    - Collapse terminal output by default.
                    - Expand into a bounded TextKit 2 scroll view.
                    """
            ),
            commandStartedItem(
                "preview-command-output",
                command:
                    "xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj -scheme CodexReviewMonitor"
            ),
            commandCompletedItem(
                "preview-command-output",
                output: output,
                exitCode: 0,
                status: .completed
            ),
            messageItem(
                "command-output-summary", text: "The output remains available without taking over the whole log."),
        ]
    }

    @_spi(PreviewSupport)
    public static func makePreviewAccounts() -> [CodexReviewAccount] {
        [
            makePreviewAccount(
                email: "workspace@example.com",
                usedPercents: (short: 34, long: 61)
            ),
            makePreviewAccount(
                email: "personal@example.com",
                usedPercents: (short: 12, long: 27)
            ),
            makePreviewAccount(
                email: "team@example.com",
                usedPercents: (short: 72, long: 44)
            ),
        ]
    }

    @_spi(PreviewSupport)
    public static func makePreviewAccount(
        email: String = "review@example.com",
        usedPercents: (short: Int, long: Int) = (short: 34, long: 61)
    ) -> CodexReviewAccount {
        let account = CodexReviewAccount(email: email, planType: "pro")
        account.updateRateLimits(
            [
                (
                    windowDurationMinutes: 300,
                    usedPercent: usedPercents.short,
                    resetsAt: Date.now.addingTimeInterval(60 * 60)
                ),
                (
                    windowDurationMinutes: 10_080,
                    usedPercent: usedPercents.long,
                    resetsAt: Date.now.addingTimeInterval(24 * 60 * 60)
                ),
            ]
        )
        return account
    }

    static func makePreviewSettingsSnapshot() -> CodexReviewSettings.Snapshot {
        .init(
            model: "gpt-5.4",
            reasoningEffort: .medium,
            serviceTier: .fast,
            models: makePreviewModelCatalog()
        )
    }

    static func makePreviewModelCatalog() -> [CodexReviewSettings.ModelCatalogItem] {
        [
            .init(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                hidden: false,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: .low, description: "Lower latency."),
                    .init(reasoningEffort: .medium, description: "Balanced default."),
                    .init(reasoningEffort: .high, description: "More deliberation."),
                ],
                defaultReasoningEffort: .medium,
                supportedServiceTiers: [.fast]
            ),
            .init(
                id: "gpt-5.4-mini",
                model: "gpt-5.4-mini",
                displayName: "GPT-5.4 Mini",
                hidden: false,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: .low, description: "Quick pass."),
                    .init(reasoningEffort: .medium, description: "Balanced default."),
                ],
                defaultReasoningEffort: .medium,
                supportedServiceTiers: []
            ),
            .init(
                id: "gpt-5.3-codex",
                model: "gpt-5.3-codex",
                displayName: "GPT-5.3 Codex",
                hidden: false,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: .minimal, description: "Lowest overhead."),
                    .init(reasoningEffort: .low, description: "Faster iteration."),
                    .init(reasoningEffort: .medium, description: "Balanced default."),
                ],
                defaultReasoningEffort: .medium,
                supportedServiceTiers: [.fast, .flex]
            ),
        ]
    }

    private static func makeSidebarContent() -> PreviewSidebarContent {
        let now = Date()
        let workspacePaths = [
            "/path/to/workspace-alpha",
            "/path/to/workspace-beta",
            "/path/to/workspace-gamma",
        ]

        var chatLogFixtures: [ReviewMonitorPreviewChatLogFixture] = []
        var reviewRuns: [ReviewRunRecord] = []
        for (workspaceIndex, cwd) in workspacePaths.enumerated() {
            let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
            for (chatIndex, definition) in makeChatDefinitions(for: workspaceName).enumerated() {
                let chatItems = makePreviewChatLogItems(for: definition, workspaceName: workspaceName)
                let chatID = CodexThreadID(rawValue: "preview-thread-\(workspaceIndex)-\(chatIndex)")
                let turnID = CodexTurnID(rawValue: "preview-turn-\(workspaceIndex)-\(chatIndex)")
                let chatFixture = PreviewChatFixture(
                    id: "preview-\(workspaceIndex)-\(chatIndex)",
                    chatID: chatID,
                    turnID: turnID,
                    cwd: cwd,
                    targetSummary: definition.targetSummary,
                    summary: definition.summary,
                    initialMessage: definition.initialMessage,
                    model: definition.model,
                    lifecycle: definition.lifecycle,
                    startedAt: definition.startedOffset.map { now.addingTimeInterval($0) },
                    endedAt: definition.endedOffset.map { now.addingTimeInterval($0) },
                    chatItems: chatItems
                )
                chatLogFixtures.append(
                    makeChatLogFixture(
                        for: chatFixture
                    ))
                reviewRuns.append(
                    makeReviewRunRecord(
                        for: chatFixture,
                        runIndex: workspaceIndex * 100 + chatIndex
                    ))
            }
        }
        return PreviewSidebarContent(
            chatLogFixtures: chatLogFixtures,
            reviewRuns: reviewRuns
        )
    }

    private static func makeReviewRunRecord(
        for chatFixture: PreviewChatFixture,
        runIndex: Int
    ) -> ReviewRunRecord {
        ReviewRunRecord(
            id: "preview-run-\(runIndex)",
            sessionID: "preview-session",
            cwd: chatFixture.cwd,
            targetSummary: chatFixture.targetSummary,
            core: .init(
                run: .init(
                    reviewThreadID: chatFixture.chatID.rawValue,
                    threadID: chatFixture.chatID.rawValue,
                    turnID: chatFixture.turnID.rawValue,
                    model: chatFixture.model
                ),
                lifecycle: .init(
                    status: ReviewRunState(chatFixture.lifecycle),
                    startedAt: chatFixture.startedAt,
                    endedAt: chatFixture.endedAt,
                    cancellation: chatFixture.lifecycle == .cancelled ? .system() : nil,
                    errorMessage: chatFixture.lifecycle == .failed ? chatFixture.summary : nil
                ),
                lifecycleMessage: chatFixture.summary
            )
        )
    }

    private static func makeChatLogFixture(
        for chatFixture: PreviewChatFixture
    ) -> ReviewMonitorPreviewChatLogFixture {
        let turn = CodexChatTurnStateSnapshot(
            id: chatFixture.turnID,
            status: CodexTurnStatus(chatFixture.lifecycle),
            errorDescription: chatFixture.lifecycle == .failed ? chatFixture.summary : nil,
            usage: nil
        )
        let initialSnapshot = CodexChatSnapshot(
            chatID: chatFixture.chatID,
            phase: CodexDataPhase(
                chatFixture.lifecycle,
                errorMessage: chatFixture.lifecycle == .failed ? chatFixture.summary : nil
            ),
            turns: [turn],
            items: makeInitialChatItems(
                streamID: chatFixture.id,
                chatItems: chatFixture.chatItems,
                turnID: turn.id
            )
        )
        return ReviewMonitorPreviewChatLogFixture(
            chatID: chatFixture.chatID,
            title: chatFixture.targetSummary,
            preview: chatFixture.initialMessage.nilIfEmpty ?? chatFixture.summary.nilIfEmpty,
            model: chatFixture.model,
            workspaceCWD: chatFixture.cwd,
            updatedAt: chatFixture.endedAt ?? chatFixture.startedAt,
            recencyAt: chatFixture.endedAt ?? chatFixture.startedAt,
            status: CodexThreadStatus(previewLifecycle: chatFixture.lifecycle),
            cwd: chatFixture.cwd,
            streamID: chatFixture.id,
            isRunning: chatFixture.lifecycle == .running,
            initialSnapshot: initialSnapshot
        )
    }

    private static func makeInitialChatItems(
        streamID: String,
        chatItems: [PreviewChatLogItemTemplate],
        turnID: CodexTurnID
    ) -> [CodexChatItemSnapshot] {
        var snapshots: [CodexChatItemSnapshot] = []
        for item in chatItems {
            let snapshot = item.itemSnapshot(
                id: previewChatLogItemID(
                    itemName: item.itemName,
                    streamID: streamID,
                    cycle: 0
                ),
                turnID: turnID
            )
            if let index = snapshots.firstIndex(where: {
                $0.id == snapshot.id && $0.turnID == snapshot.turnID
            }) {
                snapshots[index] = snapshot
            } else {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    private static func diagnosticItem(
        _ itemName: String,
        kind: CodexThreadItem.Kind,
        message: String
    ) -> PreviewChatLogItemTemplate {
        .init(
            itemName: itemName,
            kind: kind,
            content: .diagnostic(message)
        )
    }

    private static func messageItem(_ itemName: String, text: String) -> PreviewChatLogItemTemplate {
        .init(
            itemName: itemName,
            kind: .agentMessage,
            content: .message(.init(id: itemName, role: .assistant, text: text))
        )
    }

    private static func planItem(_ itemName: String, markdown: String) -> PreviewChatLogItemTemplate {
        .init(
            itemName: itemName,
            kind: .plan,
            content: .plan(markdown)
        )
    }

    private static func reasoningItem(
        _ itemName: String,
        text: String,
        style: PreviewReasoningStyle = .summary
    ) -> PreviewChatLogItemTemplate {
        .init(
            itemName: itemName,
            kind: .reasoning,
            content: .reasoning(style == .summary ? .init(summary: text) : .init(content: text))
        )
    }

    private static func contextCompactionItem(
        _ itemName: String,
        title: String
    ) -> PreviewChatLogItemTemplate {
        .init(
            itemName: itemName,
            kind: .contextCompaction,
            content: .contextCompaction(title)
        )
    }

    private static func commandStartedItem(
        _ itemName: String,
        command: String,
        cwd: String? = nil
    ) -> PreviewChatLogItemTemplate {
        .init(
            itemName: itemName,
            kind: .commandExecution,
            content: .command(
                .init(
                    command: command,
                    cwd: cwd,
                    status: .running
                ))
        )
    }

    private static func commandCompletedItem(
        _ itemName: String,
        output: String,
        exitCode: Int,
        status: CodexTurnStatus
    ) -> PreviewChatLogItemTemplate {
        .init(
            itemName: itemName,
            kind: .commandExecution,
            content: .command(
                .init(
                    command: "",
                    output: output,
                    exitCode: exitCode,
                    status: status
                ))
        )
    }

    private static func toolCallItem(
        _ itemName: String,
        result: String,
        status: CodexTurnStatus
    ) -> PreviewChatLogItemTemplate {
        return PreviewChatLogItemTemplate(
            itemName: itemName,
            kind: .mcpToolCall,
            content: .toolCall(.init(result: result, status: status))
        )
    }

    private static func makePreviewChatLogItems(
        for definition: PreviewChatDefinition,
        workspaceName: String
    ) -> [PreviewChatLogItemTemplate] {
        switch definition.lifecycle {
        case .running:
            return makeRunningPreviewChatLogItems(for: definition, workspaceName: workspaceName)
        case .queued:
            return [
                diagnosticItem(
                    "queued-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: CodexThreadItem.Kind(rawValue: "event"),
                    message: "Queued review for \(definition.targetSummary)."
                ),
                diagnosticItem(
                    "queued-progress-\(workspaceName)-\(definition.targetSummary)",
                    kind: CodexThreadItem.Kind(rawValue: "progress"),
                    message: definition.summary
                ),
            ]
        case .failed:
            let commandName = "preview-failed-command-\(workspaceName)-\(definition.targetSummary)"
            return [
                diagnosticItem(
                    "failed-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: CodexThreadItem.Kind(rawValue: "event"),
                    message: "Turn started: preview-failed-\(workspaceName.lowercased())"
                ),
                commandStartedItem(
                    commandName,
                    command: "/bin/zsh -lc \"swift test --build-system swiftbuild --no-parallel\""
                ),
                commandCompletedItem(
                    commandName,
                    output: """
                        Building for debugging...
                        Test Suite 'ReviewUITests' started.
                        ReviewMonitorContentPreviewTests.testPreviewStore failed: expected command output panel metadata.
                    """,
                    exitCode: 1,
                    status: .failed
                ),
                diagnosticItem(
                    "failed-error-\(workspaceName)-\(definition.targetSummary)",
                    kind: .error,
                    message: definition.summary
                ),
                messageItem(
                    "failed-message-\(workspaceName)-\(definition.targetSummary)", text: definition.initialMessage),
            ]
        case .cancelled:
            return [
                diagnosticItem(
                    "cancelled-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: CodexThreadItem.Kind(rawValue: "event"),
                    message: "Turn started: preview-cancelled-\(workspaceName.lowercased())"
                ),
                diagnosticItem(
                    "cancelled-progress-\(workspaceName)-\(definition.targetSummary)",
                    kind: CodexThreadItem.Kind(rawValue: "progress"),
                    message: definition.summary
                ),
                messageItem(
                    "cancelled-message-\(workspaceName)-\(definition.targetSummary)", text: definition.initialMessage),
            ]
        case .succeeded:
            let commandName = "preview-complete-command-\(workspaceName)-\(definition.targetSummary)"
            return [
                diagnosticItem(
                    "complete-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: CodexThreadItem.Kind(rawValue: "event"),
                    message: "Turn started: preview-complete-\(workspaceName.lowercased())"
                ),
                commandStartedItem(
                    commandName,
                    command: "/bin/zsh -lc \"swift test --filter ReviewUI\""
                ),
                commandCompletedItem(
                    commandName,
                    output: """
                        Test Suite 'ReviewUITests' started.
                        Test commandOutputRendersCollapsedTextKitPanelAndExpandsInline passed.
                        Test Suite 'ReviewUITests' passed.
                    """,
                    exitCode: 0,
                    status: .completed
                ),
                reasoningItem(
                    "complete-summary-\(workspaceName)-\(definition.targetSummary)",
                    text: definition.summary
                ),
                messageItem(
                    "complete-message-\(workspaceName)-\(definition.targetSummary)", text: definition.initialMessage),
            ]
        }
    }

    private static func makeRunningPreviewChatLogItems(
        for definition: PreviewChatDefinition,
        workspaceName: String
    ) -> [PreviewChatLogItemTemplate] {
        let sourceReadItemName = "preview-initial-source-read-\(workspaceName)-\(definition.targetSummary)"
        let sourceReadCommand =
            "sed -n '1,260p' Sources/ReviewUI/Detail/ReviewMonitorCommandOutputDisplayDocument.swift"
        let initialCommandName = "preview-initial-command-\(workspaceName)-\(definition.targetSummary)"
        return [
            diagnosticItem(
                "running-event-\(workspaceName)-\(definition.targetSummary)",
                kind: CodexThreadItem.Kind(rawValue: "event"),
                message: "Turn started: preview-\(workspaceName.lowercased())"
            ),
            diagnosticItem(
                "running-progress-\(workspaceName)-\(definition.targetSummary)",
                kind: CodexThreadItem.Kind(rawValue: "progress"),
                message: "Reviewing \(definition.targetSummary)"
            ),
            contextCompactionItem(
                "preview-initial-context-compaction-\(workspaceName)-\(definition.targetSummary)",
                title: "Context automatically compacted"
            ),
            planItem(
                "preview-initial-plan-\(workspaceName)-\(definition.targetSummary)",
                markdown: """
                    [completed] Inspect changed files
                    [in_progress] Check ReviewMonitor log behavior
                    [pending] Run focused tests
                    """
            ),
            commandStartedItem(
                initialCommandName,
                command: "/bin/zsh -lc \"git diff --stat && rg -n 'ReviewMonitor' Sources Tests\""
            ),
            commandCompletedItem(
                initialCommandName,
                output: """
                    Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift | 34 +++++++++++++++++
                    Sources/ReviewUI/Detail/ReviewMonitorLogDocumentView.swift | 18 ++++++++--
                    Tests/ReviewUITests/ReviewUITests.swift | 12 ++++++

                    Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift:42: private let logDocumentView = ReviewMonitorLogDocumentView()
                    Tests/ReviewUITests/ReviewUITests.swift:2322: commandOutputRendersCollapsedTextKitPanelAndExpandsInline
                    """,
                exitCode: 0,
                status: .completed
            ),
            commandStartedItem(
                sourceReadItemName,
                command: "/bin/zsh -lc \"\(sourceReadCommand)\""
            ),
            toolCallItem(
                "running-tool-\(workspaceName)-\(definition.targetSummary)",
                result: "MCP codex_review.review_start started.",
                status: .running
            ),
            reasoningItem(
                "preview-initial-summary-\(workspaceName)-\(definition.targetSummary)",
                text:
                    "I am comparing the current UI state with the streaming log updates before changing the finder integration."
            ),
            messageItem(
                "preview-initial-agent-\(workspaceName)-\(definition.targetSummary)", text: definition.initialMessage),
        ]
    }

    private static func makeChatDefinitions(for workspaceName: String) -> [PreviewChatDefinition] {
        [
            PreviewChatDefinition(
                lifecycle: .running,
                targetSummary: "Branch: feature/\(workspaceName.lowercased())-sidebar",
                summary: "Review is streaming updates from the embedded server.",
                initialMessage: "Inspecting recent sidebar changes and collecting render timings.",
                model: "gpt-5.4",
                startedOffset: -420,
                endedOffset: nil
            ),
            PreviewChatDefinition(
                lifecycle: .running,
                targetSummary: "Uncommitted changes",
                summary: "The working tree review is still in progress.",
                initialMessage: "Comparing row reuse behavior across the latest local edits.",
                model: "gpt-5.4-mini",
                startedOffset: -135,
                endedOffset: nil
            ),
            PreviewChatDefinition(
                lifecycle: .queued,
                targetSummary: "Base branch: main",
                summary: "Queued behind another active review in this workspace.",
                initialMessage: "Waiting for an available backend slot.",
                model: "gpt-5.3-codex",
                startedOffset: nil,
                endedOffset: nil
            ),
            PreviewChatDefinition(
                lifecycle: .succeeded,
                targetSummary: "Commit: abc1234",
                summary: "Review completed without correctness findings.",
                initialMessage: "No correctness issues found in the touched files.",
                model: "gpt-5.4",
                startedOffset: -1_500,
                endedOffset: -1_260
            ),
            PreviewChatDefinition(
                lifecycle: .failed,
                targetSummary: "Custom: investigate CI flake",
                summary: "The review stopped after the test command failed.",
                initialMessage: "Build failed before the model could finish evaluating the patch.",
                model: "gpt-5.3-codex",
                startedOffset: -2_400,
                endedOffset: -2_190
            ),
            PreviewChatDefinition(
                lifecycle: .cancelled,
                targetSummary: "Branch: feature/\(workspaceName.lowercased())-transport",
                summary: "Cancellation was requested after initial diagnostics completed.",
                initialMessage: "Stopped after the first pass to free the session for a retry.",
                model: "gpt-5.4-mini",
                startedOffset: -960,
                endedOffset: -840
            ),
            PreviewChatDefinition(
                lifecycle: .succeeded,
                targetSummary: "Commit: def5678",
                summary: "Review suggested a small cleanup in the sidebar row renderer.",
                initialMessage: "Suggested simplifying duplicated state handling in the row view.",
                model: "gpt-5.4",
                startedOffset: -5_400,
                endedOffset: -5_040
            ),
        ]
    }
}

private extension CodexThreadStatus {
    init(previewLifecycle lifecycle: ReviewMonitorPreviewContent.PreviewChatLifecycle) {
        switch lifecycle {
        case .queued, .running:
            self = .active(activeFlags: [])
        case .succeeded, .failed, .cancelled:
            self = .idle
        }
    }
}

private extension CodexTurnStatus {
    init(_ lifecycle: ReviewMonitorPreviewContent.PreviewChatLifecycle) {
        switch lifecycle {
        case .queued, .running:
            self = .running
        case .succeeded:
            self = .completed
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        }
    }
}

private extension ReviewRunState {
    init(_ lifecycle: ReviewMonitorPreviewContent.PreviewChatLifecycle) {
        switch lifecycle {
        case .queued:
            self = .queued
        case .running:
            self = .running
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        }
    }
}

private extension CodexDataPhase {
    init(_ lifecycle: ReviewMonitorPreviewContent.PreviewChatLifecycle, errorMessage: String?) {
        switch lifecycle {
        case .queued, .running, .succeeded, .cancelled:
            self = .loaded
        case .failed:
            self = .failed(errorMessage ?? "Review failed")
        }
    }
}
