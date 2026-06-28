import Foundation
import CodexKit
@_spi(Testing) import CodexReviewKit

@_spi(PreviewSupport)
@MainActor
public enum ReviewMonitorPreviewContent {
    private struct PreviewJobDefinition {
        let status: ReviewJobState
        let targetSummary: String
        let summary: String
        let lastAgentMessage: String
        let model: String
        let startedOffset: TimeInterval?
        let endedOffset: TimeInterval?
        let hasFinalReview: Bool
    }

    private struct PreviewStreamTemplate {
        let itemName: String?
        let kind: ReviewItemKind
        let family: ReviewItemFamily
        let phase: ReviewItemPhase
        let content: ReviewTimelineItem.Content
        let mode: PreviewStreamMode
        let deltaText: String?
        let startedAt: Date?
        let completedAt: Date?
        let durationMs: Int?
        let chunkByWord: Bool
        let delayBeforeFrameCount: Int
        let chunkIntervalFrameCount: Int

        init(
            itemName: String? = nil,
            kind: ReviewItemKind,
            family: ReviewItemFamily,
            phase: ReviewItemPhase = .completed,
            content: ReviewTimelineItem.Content,
            mode: PreviewStreamMode = .complete,
            deltaText: String? = nil,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            durationMs: Int? = nil,
            chunkByWord: Bool = false,
            delayBeforeFrameCount: Int,
            chunkIntervalFrameCount: Int = 1
        ) {
            self.itemName = itemName
            self.kind = kind
            self.family = family
            self.phase = phase
            self.content = content
            self.mode = mode
            self.deltaText = deltaText
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMs = durationMs
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

    private struct PreviewTimelineItemTemplate {
        let itemName: String
        let kind: ReviewItemKind
        let family: ReviewItemFamily
        let phase: ReviewItemPhase
        let content: ReviewTimelineItem.Content
        let startedAt: Date?
        let completedAt: Date?
        let durationMs: Int?

        init(
            itemName: String,
            kind: ReviewItemKind,
            family: ReviewItemFamily,
            phase: ReviewItemPhase,
            content: ReviewTimelineItem.Content,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            durationMs: Int? = nil
        ) {
            self.itemName = itemName
            self.kind = kind
            self.family = family
            self.phase = phase
            self.content = content
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMs = durationMs
        }

        func seed(id: ReviewTimelineItem.ID) -> ReviewTimelineItemSeed {
            .init(
                id: id,
                kind: kind,
                family: family,
                phase: phase,
                content: content,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: durationMs
            )
        }
    }

    package struct PreviewTimelineStep {
        let itemName: String
        let kind: ReviewItemKind
        let family: ReviewItemFamily
        let phase: ReviewItemPhase
        let content: ReviewTimelineItem.Content
        let mode: PreviewStreamMode
        let deltaText: String?
        let startedAt: Date?
        let completedAt: Date?
        let durationMs: Int?

        func seed(id: ReviewTimelineItem.ID) -> ReviewTimelineItemSeed {
            .init(
                id: id,
                kind: kind,
                family: family,
                phase: phase,
                content: content,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: durationMs
            )
        }
    }

    package struct PreviewStreamFrame {
        let step: PreviewTimelineStep
        let cycle: Int
    }

    private struct PreviewSidebarContent {
        var workspaces: [CodexReviewWorkspace]
        var jobs: [CodexReviewJob]
        var chatLogFixtures: [ReviewMonitorPreviewChatLogFixture]
    }

    @_spi(PreviewSupport)
    public static func makeStore() -> CodexReviewStore {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: makePreviewSettingsSnapshot())
        )
        let accounts = makePreviewAccounts()
        let previewContent = makeSidebarContent()
        store.loadForTesting(
            serverState: .running,
            account: accounts.first,
            persistedAccounts: accounts,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: previewContent.workspaces,
            jobs: previewContent.jobs
        )
        let chatLogSource = ReviewMonitorPreviewChatLogSource(
            fixtures: previewContent.chatLogFixtures
        )
        store.previewSupportRetainer = ReviewMonitorPreviewRuntimeSupport(
            chatLogSource: chatLogSource
        )
        return store
    }

    static func makeChatLogSource(from store: CodexReviewStore) -> ReviewMonitorPreviewChatLogSource {
        if let previewSupport = store.previewSupportRetainer as? ReviewMonitorPreviewRuntimeSupport {
            return previewSupport.chatLogSource
        }
        return ReviewMonitorPreviewChatLogSource(fixtures: [])
    }

    static func retainChatLogStreamer(
        source: ReviewMonitorPreviewChatLogSource,
        in store: CodexReviewStore,
        interval: Duration
    ) {
        let previewSupport: ReviewMonitorPreviewRuntimeSupport
        if let existingSupport = store.previewSupportRetainer as? ReviewMonitorPreviewRuntimeSupport,
           existingSupport.chatLogSource === source {
            previewSupport = existingSupport
        } else {
            previewSupport = ReviewMonitorPreviewRuntimeSupport(chatLogSource: source)
            store.previewSupportRetainer = previewSupport
        }
        previewSupport.startStreaming(interval: interval)
    }

    @_spi(PreviewSupport)
    public static func makeCommandOutputStore() -> CodexReviewStore {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: makePreviewSettingsSnapshot())
        )
        let accounts = makePreviewAccounts()
        let cwd = "/path/to/workspace-alpha"
        let now = Date()
        let timelineItems = makeCommandOutputPreviewTimelineItems()
        let job = makeJob(
            id: "preview-command-output-panel",
            cwd: cwd,
            model: "gpt-5.4",
            status: .running,
            targetSummary: "Command output panel",
            startedAt: now.addingTimeInterval(-135),
            endedAt: nil,
            summary: "A command output block is collapsed by default.",
            hasFinalReview: false,
            reviewResult: nil,
            lastAgentMessage: "Opened command output should stay bounded to a short embedded scroll view."
        )
        store.loadForTesting(
            serverState: .running,
            account: accounts.first,
            persistedAccounts: accounts,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: [CodexReviewWorkspace(cwd: cwd)],
            jobs: [job]
        )
        if let fixture = makeChatLogFixture(for: job, timelineItems: timelineItems) {
            store.previewSupportRetainer = ReviewMonitorPreviewRuntimeSupport(
                chatLogSource: ReviewMonitorPreviewChatLogSource(fixtures: [fixture])
            )
        }
        return store
    }

    package static func streamFrame(
        forRunningChatAt runningChatIndex: Int,
        tick: Int
    ) -> PreviewStreamFrame? {
        guard previewStreamTimeline.isEmpty == false else {
            return nil
        }
        let chatTick = tick - runningChatIndex * previewChatTickOffset
        guard chatTick > 0 else {
            return nil
        }

        let offset = (chatTick - 1) % previewStreamTimeline.count
        guard let step = previewStreamTimeline[offset] else {
            return nil
        }
        return PreviewStreamFrame(
            step: step,
            cycle: (chatTick - 1) / previewStreamTimeline.count
        )
    }

    package static func previewTimelineItemID(
        itemName: String,
        jobID: String,
        cycle: Int
    ) -> ReviewTimelineItem.ID {
        .init(rawValue: "preview-\(itemName)-\(jobID)-\(cycle)")
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

    private static func streamTimeline(from templates: [PreviewStreamTemplate]) -> [PreviewTimelineStep?] {
        var timeline: [PreviewTimelineStep?] = []
        for (templateIndex, template) in templates.enumerated() {
            let delay = timeline.isEmpty ? 1 : max(1, template.delayBeforeFrameCount)
            if delay > 1 {
                timeline.append(contentsOf: Array(repeating: nil, count: delay - 1))
            }
            let itemName = template.itemName ?? "stream-\(templateIndex)"
            let streamText = template.deltaText ?? ""
            let chunks = template.chunkByWord ? wordChunks(in: streamText) : [streamText]
            for (index, chunk) in chunks.enumerated() {
                if index > 0 && template.chunkIntervalFrameCount > 1 {
                    timeline.append(contentsOf: Array(repeating: nil, count: template.chunkIntervalFrameCount - 1))
                }
                timeline.append(
                    PreviewTimelineStep(
                        itemName: itemName,
                        kind: template.kind,
                        family: template.family,
                        phase: template.phase,
                        content: template.content,
                        mode: template.mode,
                        deltaText: template.mode == .textDelta ? chunk : template.deltaText,
                        startedAt: template.startedAt,
                        completedAt: template.completedAt,
                        durationMs: template.durationMs
                    ))
            }
        }
        return timeline
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
            kind: ReviewItemKind(rawValue: "event"),
            family: .diagnostic,
            content: .diagnostic(.init(message: "Turn started: \(previewTurnID(1))")),
            delayBeforeFrameCount: 1
        ),
        .init(
            itemName: "plan",
            kind: .plan,
            family: .plan,
            content: .plan(
                .init(
                    markdown: """
                        [completed] Inspect ReviewMonitor log rendering
                        [in_progress] Preserve active find UI while streaming
                        [pending] Run focused UI tests
                        """)),
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-search-test",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(
                .init(
                    command:
                        "/bin/zsh -lc \"rg -n 'ReviewMonitorLog' Sources/ReviewUI && swift test --filter ReviewUI\"",
                    status: .inProgress
                )),
            mode: .update,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-search-test",
            kind: .commandExecution,
            family: .command,
            phase: .completed,
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
            family: .tool,
            content: .toolCall(
                .init(
                    result: "MCP codex_review.review_read started.",
                    status: .started
                )),
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "reasoning-summary",
            kind: .reasoning,
            family: .reasoning,
            content: .reasoning(.init(text: "", style: .summary)),
            mode: .textDelta,
            deltaText:
                "Checking whether append-only log updates are notifying NSTextFinder while an incremental search is active.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-open-log-scroll",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(
                .init(
                    command:
                        "/bin/zsh -lc \"sed -n '1,240p' Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift\"",
                    status: .inProgress
                )),
            mode: .update,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "command-open-log-scroll",
            kind: .commandExecution,
            family: .command,
            phase: .completed,
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
            family: .contextCompaction,
            phase: .running,
            content: .contextCompaction(
                .init(
                    title: "Automatically compacting context",
                    status: .inProgress
                )),
            mode: .update,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "context-compaction",
            kind: .contextCompaction,
            family: .contextCompaction,
            phase: .completed,
            content: .contextCompaction(
                .init(
                    title: "Context automatically compacted",
                    status: .completed
                )),
            delayBeforeFrameCount: compactionCompletionDelayFrameCount
        ),
        .init(
            kind: .mcpToolCall,
            family: .tool,
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
            family: .reasoning,
            content: .reasoning(.init(text: "", style: .raw)),
            mode: .textDelta,
            deltaText:
                "Need to avoid refreshing the finder client string until the user closes or clears the find bar. Appended text can wait for the next search session.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "raw-reasoning-follow-up",
            kind: .reasoning,
            family: .reasoning,
            content: .reasoning(.init(text: "", style: .raw)),
            mode: .textDelta,
            deltaText:
                "I found the log update path and am keeping the current find session stable while new output streams in.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            itemName: "agent-message-summary",
            kind: .agentMessage,
            family: .message,
            content: .message(
                .init(
                    text:
                        "The preview stream now mixes commands, tool events, reasoning summaries, and visible assistant output instead of one repeated message kind.\n",
                )),
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
    ]

    private static let previewStreamTimeline = streamTimeline(from: previewStreamTemplates)

    private static func makeCommandOutputPreviewTimelineItems() -> [PreviewTimelineItemTemplate] {
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
                kind: ReviewItemKind(rawValue: "event"),
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

        var workspaces: [CodexReviewWorkspace] = []
        var jobs: [CodexReviewJob] = []
        var chatLogFixtures: [ReviewMonitorPreviewChatLogFixture] = []
        for (workspaceIndex, cwd) in workspacePaths.enumerated() {
            let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
            workspaces.append(CodexReviewWorkspace(cwd: cwd))
            for (jobIndex, definition) in makeJobDefinitions(for: workspaceName).enumerated() {
                let timelineItems = makePreviewTimelineItems(for: definition, workspaceName: workspaceName)
                let job = makeJob(
                    id: "preview-\(workspaceIndex)-\(jobIndex)",
                    cwd: cwd,
                    model: definition.model,
                    status: definition.status,
                    targetSummary: definition.targetSummary,
                    startedAt: definition.startedOffset.map { now.addingTimeInterval($0) },
                    endedAt: definition.endedOffset.map { now.addingTimeInterval($0) },
                    summary: definition.summary,
                    hasFinalReview: definition.hasFinalReview,
                    reviewResult: makeReviewResult(
                        workspaceIndex: workspaceIndex,
                        jobIndex: jobIndex,
                        cwd: cwd
                    ),
                    lastAgentMessage: definition.lastAgentMessage
                )
                jobs.append(job)
                if let fixture = makeChatLogFixture(for: job, timelineItems: timelineItems) {
                    chatLogFixtures.append(fixture)
                }
            }
        }
        return PreviewSidebarContent(
            workspaces: workspaces,
            jobs: jobs,
            chatLogFixtures: chatLogFixtures
        )
    }

    private static func makeChatLogFixture(
        for job: CodexReviewJob,
        timelineItems: [PreviewTimelineItemTemplate]
    ) -> ReviewMonitorPreviewChatLogFixture? {
        guard let chat = job.legacyReviewChatSelection else {
            return nil
        }
        let turn = CodexChatTurnStateSnapshot(
            id: job.previewTurnID,
            status: CodexTurnStatus(job.core.lifecycle.status),
            errorDescription: job.core.lifecycle.errorMessage,
            usage: nil
        )
        let initialSnapshot = CodexChatSnapshot(
            chatID: chat.id,
            phase: CodexDataPhase(
                job.core.lifecycle.status,
                errorMessage: job.core.lifecycle.errorMessage
            ),
            turns: [turn],
            items: makeInitialChatItems(
                for: job,
                timelineItems: timelineItems,
                turnID: turn.id
            )
        )
        return ReviewMonitorPreviewChatLogFixture(
            chat: chat,
            cwd: job.cwd,
            streamID: job.id,
            isRunning: job.core.lifecycle.status == .running,
            initialSnapshot: initialSnapshot
        )
    }

    private static func makeInitialChatItems(
        for job: CodexReviewJob,
        timelineItems: [PreviewTimelineItemTemplate],
        turnID: CodexTurnID
    ) -> [CodexChatItemSnapshot] {
        let timeline = ReviewTimeline()
        for item in timelineItems {
            let itemID = previewTimelineItemID(
                itemName: item.itemName,
                jobID: job.id,
                cycle: 0
            )
            let seed = item.seed(id: itemID)
            let event: ReviewDomainEvent = item.phase.isTerminal ? .itemCompleted(seed) : .itemUpdated(seed)
            timeline.apply(event)
        }
        return timeline.items.map {
            CodexChatItemSnapshot(previewItem: $0, turnID: turnID)
        }
    }

    private static func makeJob(
        id: String,
        cwd: String,
        model: String,
        status: ReviewJobState,
        targetSummary: String,
        startedAt: Date?,
        endedAt: Date?,
        summary: String,
        hasFinalReview: Bool,
        reviewResult: ParsedReviewResult?,
        lastAgentMessage: String
    ) -> CodexReviewJob {
        CodexReviewJob.makeForTesting(
            id: id,
            cwd: cwd,
            targetSummary: targetSummary,
            model: model,
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: status,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            hasFinalReview: hasFinalReview,
            reviewResult: reviewResult,
            lastAgentMessage: lastAgentMessage
        )
    }

    private static func diagnosticItem(
        _ itemName: String,
        kind: ReviewItemKind,
        message: String,
        phase: ReviewItemPhase = .completed
    ) -> PreviewTimelineItemTemplate {
        .init(
            itemName: itemName,
            kind: kind,
            family: .diagnostic,
            phase: phase,
            content: .diagnostic(.init(message: message))
        )
    }

    private static func messageItem(_ itemName: String, text: String) -> PreviewTimelineItemTemplate {
        .init(
            itemName: itemName,
            kind: .agentMessage,
            family: .message,
            phase: .completed,
            content: .message(.init(text: text))
        )
    }

    private static func planItem(_ itemName: String, markdown: String) -> PreviewTimelineItemTemplate {
        .init(
            itemName: itemName,
            kind: .plan,
            family: .plan,
            phase: .completed,
            content: .plan(.init(markdown: markdown))
        )
    }

    private static func reasoningItem(
        _ itemName: String,
        text: String,
        style: ReviewTimelineItem.Reasoning.Style = .summary
    ) -> PreviewTimelineItemTemplate {
        .init(
            itemName: itemName,
            kind: .reasoning,
            family: .reasoning,
            phase: .completed,
            content: .reasoning(.init(text: text, style: style))
        )
    }

    private static func contextCompactionItem(
        _ itemName: String,
        title: String,
        status: ReviewContextCompactionStatus
    ) -> PreviewTimelineItemTemplate {
        .init(
            itemName: itemName,
            kind: .contextCompaction,
            family: .contextCompaction,
            phase: status == .completed ? .completed : .running,
            content: .contextCompaction(.init(title: title, status: status))
        )
    }

    private static func commandStartedItem(
        _ itemName: String,
        command: String,
        cwd: String? = nil,
        startedAt: Date? = nil,
        actions: [ReviewTimelineItem.CommandAction] = []
    ) -> PreviewTimelineItemTemplate {
        .init(
            itemName: itemName,
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(
                .init(
                    command: command,
                    cwd: cwd,
                    status: .inProgress,
                    actions: actions
                )),
            startedAt: startedAt
        )
    }

    private static func commandCompletedItem(
        _ itemName: String,
        output: String,
        exitCode: Int,
        status: ReviewCommandStatus,
        durationMs: Int? = nil
    ) -> PreviewTimelineItemTemplate {
        .init(
            itemName: itemName,
            kind: .commandExecution,
            family: .command,
            phase: status == .failed ? .failed : .completed,
            content: .command(
                .init(
                    command: "",
                    output: output,
                    exitCode: exitCode,
                    status: status,
                    durationMs: durationMs
                )),
            durationMs: durationMs
        )
    }

    private static func toolCallItem(
        _ itemName: String,
        result: String,
        status: ReviewToolCallStatus
    ) -> PreviewTimelineItemTemplate {
        let phase: ReviewItemPhase =
            switch status {
            case .started, .inProgress:
                .running
            case .failed:
                .failed
            case .cancelled:
                .cancelled
            default:
                .completed
            }
        return PreviewTimelineItemTemplate(
            itemName: itemName,
            kind: .mcpToolCall,
            family: .tool,
            phase: phase,
            content: .toolCall(.init(result: result, status: status))
        )
    }

    private static func makeReviewResult(
        workspaceIndex: Int,
        jobIndex: Int,
        cwd: String
    ) -> ParsedReviewResult? {
        guard workspaceIndex == 0,
            jobIndex == 3
        else {
            return nil
        }

        return .init(
            state: .hasFindings,
            findingCount: 2,
            findings: [
                .init(
                    title: "[P1] Keep workspace selection wired to findings",
                    body:
                        "The preview should make the first workspace show structured review findings as soon as it is selected.",
                    priority: 1,
                    location: .init(
                        path: "\(cwd)/Sources/ReviewMonitorContentView.swift",
                        startLine: 42,
                        endLine: 48
                    ),
                    rawText: ""
                ),
                .init(
                    title: "[P2] Preserve review mode preview data",
                    body: "The application review mode should keep using the same preview store as Xcode previews.",
                    priority: 2,
                    location: .init(
                        path: "\(cwd)/Tools/ReviewMonitor/ReviewMonitorApp.swift",
                        startLine: 96,
                        endLine: 104
                    ),
                    rawText: ""
                ),
            ],
            source: .parsedFinalReviewText
        )
    }

    private static func makePreviewTimelineItems(
        for definition: PreviewJobDefinition,
        workspaceName: String
    ) -> [PreviewTimelineItemTemplate] {
        switch definition.status {
        case .running:
            return makeRunningPreviewTimelineItems(for: definition, workspaceName: workspaceName)
        case .queued:
            return [
                diagnosticItem(
                    "queued-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: ReviewItemKind(rawValue: "event"),
                    message: "Queued review for \(definition.targetSummary)."
                ),
                diagnosticItem(
                    "queued-progress-\(workspaceName)-\(definition.targetSummary)",
                    kind: ReviewItemKind(rawValue: "progress"),
                    message: definition.summary
                ),
            ]
        case .failed:
            let commandName = "preview-failed-command-\(workspaceName)-\(definition.targetSummary)"
            return [
                diagnosticItem(
                    "failed-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: ReviewItemKind(rawValue: "event"),
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
                    status: .failed,
                    durationMs: 10_000
                ),
                diagnosticItem(
                    "failed-error-\(workspaceName)-\(definition.targetSummary)",
                    kind: ReviewItemKind(rawValue: "error"),
                    message: definition.summary
                ),
                messageItem(
                    "failed-message-\(workspaceName)-\(definition.targetSummary)", text: definition.lastAgentMessage),
            ]
        case .cancelled:
            return [
                diagnosticItem(
                    "cancelled-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: ReviewItemKind(rawValue: "event"),
                    message: "Turn started: preview-cancelled-\(workspaceName.lowercased())"
                ),
                diagnosticItem(
                    "cancelled-progress-\(workspaceName)-\(definition.targetSummary)",
                    kind: ReviewItemKind(rawValue: "progress"),
                    message: definition.summary
                ),
                messageItem(
                    "cancelled-message-\(workspaceName)-\(definition.targetSummary)", text: definition.lastAgentMessage),
            ]
        case .succeeded:
            let commandName = "preview-complete-command-\(workspaceName)-\(definition.targetSummary)"
            return [
                diagnosticItem(
                    "complete-event-\(workspaceName)-\(definition.targetSummary)",
                    kind: ReviewItemKind(rawValue: "event"),
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
                    status: .completed,
                    durationMs: 4_000
                ),
                reasoningItem(
                    "complete-summary-\(workspaceName)-\(definition.targetSummary)",
                    text: definition.summary
                ),
                messageItem(
                    "complete-message-\(workspaceName)-\(definition.targetSummary)", text: definition.lastAgentMessage),
            ]
        }
    }

    private static func makeRunningPreviewTimelineItems(
        for definition: PreviewJobDefinition,
        workspaceName: String
    ) -> [PreviewTimelineItemTemplate] {
        let sourceReadItemName = "preview-initial-source-read-\(workspaceName)-\(definition.targetSummary)"
        let sourceReadCommand =
            "sed -n '1,260p' Sources/ReviewUI/Detail/ReviewMonitorCommandOutputDisplayDocument.swift"
        let initialCommandName = "preview-initial-command-\(workspaceName)-\(definition.targetSummary)"
        return [
            diagnosticItem(
                "running-event-\(workspaceName)-\(definition.targetSummary)",
                kind: ReviewItemKind(rawValue: "event"),
                message: "Turn started: preview-\(workspaceName.lowercased())"
            ),
            diagnosticItem(
                "running-progress-\(workspaceName)-\(definition.targetSummary)",
                kind: ReviewItemKind(rawValue: "progress"),
                message: "Reviewing \(definition.targetSummary)"
            ),
            contextCompactionItem(
                "preview-initial-context-compaction-\(workspaceName)-\(definition.targetSummary)",
                title: "Context automatically compacted",
                status: .completed
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
                status: .completed,
                durationMs: 6_000
            ),
            commandStartedItem(
                sourceReadItemName,
                command: "/bin/zsh -lc \"\(sourceReadCommand)\"",
                startedAt: Date().addingTimeInterval(-88),
                actions: [
                    .init(
                        kind: .read,
                        command: sourceReadCommand,
                        name: "ReviewMonitorCommandOutputDisplayDocument.swift",
                        path: "Sources/ReviewUI/Detail/ReviewMonitorCommandOutputDisplayDocument.swift"
                    )
                ]
            ),
            toolCallItem(
                "running-tool-\(workspaceName)-\(definition.targetSummary)",
                result: "MCP codex_review.review_start started.",
                status: .started
            ),
            reasoningItem(
                "preview-initial-summary-\(workspaceName)-\(definition.targetSummary)",
                text:
                    "I am comparing the current UI state with the streaming log updates before changing the finder integration."
            ),
            messageItem(
                "preview-initial-agent-\(workspaceName)-\(definition.targetSummary)", text: definition.lastAgentMessage),
        ]
    }

    private static func makeJobDefinitions(for workspaceName: String) -> [PreviewJobDefinition] {
        [
            PreviewJobDefinition(
                status: .running,
                targetSummary: "Branch: feature/\(workspaceName.lowercased())-sidebar",
                summary: "Review is streaming updates from the embedded server.",
                lastAgentMessage: "Inspecting recent sidebar changes and collecting render timings.",
                model: "gpt-5.4",
                startedOffset: -420,
                endedOffset: nil,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .running,
                targetSummary: "Uncommitted changes",
                summary: "The working tree review is still in progress.",
                lastAgentMessage: "Comparing row reuse behavior across the latest local edits.",
                model: "gpt-5.4-mini",
                startedOffset: -135,
                endedOffset: nil,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .queued,
                targetSummary: "Base branch: main",
                summary: "Queued behind another active review in this workspace.",
                lastAgentMessage: "Waiting for an available backend slot.",
                model: "gpt-5.3-codex",
                startedOffset: nil,
                endedOffset: nil,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .succeeded,
                targetSummary: "Commit: abc1234",
                summary: "Review completed without correctness findings.",
                lastAgentMessage: "No correctness issues found in the touched files.",
                model: "gpt-5.4",
                startedOffset: -1_500,
                endedOffset: -1_260,
                hasFinalReview: true
            ),
            PreviewJobDefinition(
                status: .failed,
                targetSummary: "Custom: investigate CI flake",
                summary: "The review stopped after the test command failed.",
                lastAgentMessage: "Build failed before the model could finish evaluating the patch.",
                model: "gpt-5.3-codex",
                startedOffset: -2_400,
                endedOffset: -2_190,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .cancelled,
                targetSummary: "Branch: feature/\(workspaceName.lowercased())-transport",
                summary: "Cancellation was requested after initial diagnostics completed.",
                lastAgentMessage: "Stopped after the first pass to free the session for a retry.",
                model: "gpt-5.4-mini",
                startedOffset: -960,
                endedOffset: -840,
                hasFinalReview: false
            ),
            PreviewJobDefinition(
                status: .succeeded,
                targetSummary: "Commit: def5678",
                summary: "Review suggested a small cleanup in the sidebar row renderer.",
                lastAgentMessage: "Suggested simplifying duplicated state handling in the row view.",
                model: "gpt-5.4",
                startedOffset: -5_400,
                endedOffset: -5_040,
                hasFinalReview: true
            ),
        ]
    }
}

private extension CodexReviewJob {
    var previewTurnID: CodexTurnID {
        core.run.turnID.map(CodexTurnID.init(rawValue:)) ?? CodexTurnID(rawValue: "\(id):preview-turn")
    }
}

private extension CodexTurnStatus {
    init(_ jobState: ReviewJobState) {
        switch jobState {
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

private extension CodexDataPhase {
    init(_ jobState: ReviewJobState, errorMessage: String?) {
        switch jobState {
        case .queued, .running, .succeeded, .cancelled:
            self = .loaded
        case .failed:
            self = .failed(errorMessage ?? "Review failed")
        }
    }
}
