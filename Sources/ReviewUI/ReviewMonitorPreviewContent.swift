import Foundation
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
        let kind: ReviewLogEntry.Kind
        let groupName: String?
        let text: String
        let metadata: ReviewLogEntry.Metadata?
        let replacesGroup: Bool
        let chunkByWord: Bool
        let delayBeforeFrameCount: Int
        let chunkIntervalFrameCount: Int

        init(
            kind: ReviewLogEntry.Kind,
            groupName: String? = nil,
            text: String,
            metadata: ReviewLogEntry.Metadata? = nil,
            replacesGroup: Bool = false,
            chunkByWord: Bool = false,
            delayBeforeFrameCount: Int,
            chunkIntervalFrameCount: Int = 1
        ) {
            self.kind = kind
            self.groupName = groupName
            self.text = text
            self.metadata = metadata
            self.replacesGroup = replacesGroup
            self.chunkByWord = chunkByWord
            self.delayBeforeFrameCount = delayBeforeFrameCount
            self.chunkIntervalFrameCount = chunkIntervalFrameCount
        }
    }

    private struct PreviewStreamStep {
        let kind: ReviewLogEntry.Kind
        let groupName: String?
        let text: String
        let metadata: ReviewLogEntry.Metadata?
        let replacesGroup: Bool
    }

    private struct PreviewStreamFrame {
        let step: PreviewStreamStep
        let cycle: Int
    }

    @MainActor
    private final class PreviewLogStreamer {
        private weak var store: CodexReviewStore?
        private let interval: Duration
        private var task: Task<Void, Never>?
        private var tick = 0

        init(store: CodexReviewStore, interval: Duration) {
            self.store = store
            self.interval = interval
            task = Task { [weak self, interval] in
                while Task.isCancelled == false {
                    try? await Task.sleep(for: interval)
                    guard let self, Task.isCancelled == false else {
                        return
                    }
                    self.emitTick()
                }
            }
        }

        deinit {
            task?.cancel()
        }

        private func emitTick() {
            guard let store else {
                task?.cancel()
                return
            }

            tick = ReviewMonitorPreviewContent.appendPreviewStreamTick(
                to: store,
                after: tick
            )
        }
    }

    @_spi(PreviewSupport)
    public static func makeStore(
        streamInterval: Duration? = .milliseconds(40)
    ) -> CodexReviewStore {
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
        if let streamInterval {
            store.previewSupportRetainer = PreviewLogStreamer(
                store: store,
                interval: streamInterval
            )
        }
        return store
    }

    @_spi(PreviewSupport)
    public static func makeCommandOutputStore() -> CodexReviewStore {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: makePreviewSettingsSnapshot())
        )
        let accounts = makePreviewAccounts()
        let cwd = "/path/to/workspace-alpha"
        let now = Date()
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
            lastAgentMessage: "Opened command output should stay bounded to a short embedded scroll view.",
            logEntries: makeCommandOutputPreviewLogEntries()
        )
        store.loadForTesting(
            serverState: .running,
            account: accounts.first,
            persistedAccounts: accounts,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: [CodexReviewWorkspace(cwd: cwd)],
            jobs: [job]
        )
        return store
    }

    @_spi(PreviewSupport)
    public static func appendPreviewStreamTick(to store: CodexReviewStore) {
        _ = appendPreviewStreamTick(to: store, after: 0)
    }

    @discardableResult
    package static func appendPreviewStreamTick(
        to store: CodexReviewStore,
        after currentTick: Int
    ) -> Int {
        let runningJobs = store.orderedJobs
            .filter { $0.core.lifecycle.status == .running }

        guard runningJobs.isEmpty == false else {
            return currentTick
        }

        let nextTick = currentTick + 1
        for (index, job) in runningJobs.enumerated() {
            if let frame = streamFrame(forJobAt: index, tick: nextTick) {
                let entry = streamEntry(from: frame.step, for: job, cycle: frame.cycle)
                job.appendLogEntry(entry)
                appendPreviewTimelineEntry(entry, to: job)
            }
        }
        return nextTick
    }

    private static func streamFrame(
        forJobAt jobIndex: Int,
        tick: Int
    ) -> PreviewStreamFrame? {
        guard previewStreamTimeline.isEmpty == false else {
            return nil
        }
        let jobTick = tick - jobIndex * previewJobTickOffset
        guard jobTick > 0 else {
            return nil
        }

        let offset = (jobTick - 1) % previewStreamTimeline.count
        guard let step = previewStreamTimeline[offset] else {
            return nil
        }
        return PreviewStreamFrame(
            step: step,
            cycle: (jobTick - 1) / previewStreamTimeline.count
        )
    }

    private static func streamEntry(
        from step: PreviewStreamStep,
        for job: CodexReviewJob,
        cycle: Int
    ) -> ReviewLogEntry {
        let groupID = step.groupName.map { "preview-\($0)-\(job.id)-\(cycle)" }
        return .init(
            kind: step.kind,
            groupID: groupID,
            replacesGroup: step.replacesGroup,
            text: step.text,
            metadata: streamMetadata(from: step, groupID: groupID)
        )
    }

    private static func streamMetadata(
        from step: PreviewStreamStep,
        groupID: String?
    ) -> ReviewLogEntry.Metadata? {
        switch step.kind {
        case .command:
            let command = commandText(from: step.text)
            let startedAt = Date()
            return .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: groupID,
                command: command,
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        case .commandOutput:
            guard let metadata = step.metadata else {
                return nil
            }
            return commandOutputCompletionMetadata(
                from: metadata,
                groupID: groupID,
                completedAt: Date()
            )
        case .agentMessage, .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning,
            .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return step.metadata
        }
    }

    private static func commandOutputCompletionMetadata(
        from metadata: ReviewLogEntry.Metadata,
        groupID: String?,
        completedAt: Date
    ) -> ReviewLogEntry.Metadata {
        .init(
            sourceType: metadata.sourceType,
            title: metadata.title,
            status: metadata.status,
            detail: metadata.detail,
            itemID: metadata.itemID ?? groupID,
            command: metadata.command,
            cwd: metadata.cwd,
            exitCode: metadata.exitCode,
            startedAt: metadata.startedAt,
            completedAt: metadata.completedAt ?? completedAt,
            durationMs: metadata.durationMs,
            commandActions: metadata.commandActions,
            commandStatus: metadata.commandStatus ?? metadata.status ?? "completed",
            namespace: metadata.namespace,
            server: metadata.server,
            tool: metadata.tool,
            query: metadata.query,
            path: metadata.path,
            resultText: metadata.resultText,
            errorText: metadata.errorText
        )
    }

    private static func commandText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$ ") else {
            return trimmed.nilIfEmpty
        }
        return String(trimmed.dropFirst(2)).nilIfEmpty
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

    private static func streamTimeline(from templates: [PreviewStreamTemplate]) -> [PreviewStreamStep?] {
        var timeline: [PreviewStreamStep?] = []
        for template in templates {
            let delay = timeline.isEmpty ? 1 : max(1, template.delayBeforeFrameCount)
            if delay > 1 {
                timeline.append(contentsOf: Array(repeating: nil, count: delay - 1))
            }
            let chunks = template.chunkByWord ? wordChunks(in: template.text) : [template.text]
            for (index, chunk) in chunks.enumerated() {
                if index > 0 && template.chunkIntervalFrameCount > 1 {
                    timeline.append(contentsOf: Array(repeating: nil, count: template.chunkIntervalFrameCount - 1))
                }
                timeline.append(
                    PreviewStreamStep(
                        kind: template.kind,
                        groupName: template.groupName,
                        text: chunk,
                        metadata: template.metadata,
                        replacesGroup: template.replacesGroup
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
    private static let previewJobTickOffset = 21

    private static let previewStreamTemplates: [PreviewStreamTemplate] = [
        .init(
            kind: .event,
            text: "Turn started: \(previewTurnID(1))",
            delayBeforeFrameCount: 1
        ),
        .init(
            kind: .plan,
            groupName: "plan",
            text: """
                [completed] Inspect ReviewMonitor log rendering
                [in_progress] Preserve active find UI while streaming
                [pending] Run focused UI tests
                """,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .command,
            groupName: "command-search-test",
            text: "$ /bin/zsh -lc \"rg -n 'ReviewMonitorLog' Sources/ReviewUI && swift test --filter ReviewUI\"",
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .commandOutput,
            groupName: "command-search-test",
            text: """
                Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift:42: private let logDocumentView = ReviewMonitorLogDocumentView()
                Sources/ReviewUI/Detail/ReviewMonitorLogDocumentView.swift:20: final class ReviewMonitorLogDocumentView
                Test Suite 'ReviewUITests' passed.
                """,
            metadata: .init(
                sourceType: "command",
                title: "Ran command for 5s",
                status: "succeeded",
                exitCode: 0
            ),
            delayBeforeFrameCount: commandCompletionDelayFrameCount
        ),
        .init(
            kind: .toolCall,
            text: "MCP codex_review.review_read started.",
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .reasoningSummary,
            groupName: "reasoning-summary",
            text:
                "Checking whether append-only log updates are notifying NSTextFinder while an incremental search is active.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .command,
            groupName: "command-open-log-scroll",
            text: "$ /bin/zsh -lc \"sed -n '1,240p' Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift\"",
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .commandOutput,
            groupName: "command-open-log-scroll",
            text: """
                import AppKit
                import ObjectiveC.runtime
                import CodexReviewKit

                @MainActor
                final class ReviewMonitorLogScrollView: NSScrollView {
                    private let logDocumentView = ReviewMonitorLogDocumentView()
                """,
            metadata: .init(
                sourceType: "command",
                title: "Ran command for 2s",
                status: "succeeded",
                exitCode: 0
            ),
            delayBeforeFrameCount: commandCompletionDelayFrameCount
        ),
        .init(
            kind: .contextCompaction,
            groupName: "context-compaction",
            text: "Automatically compacting context",
            metadata: .init(
                sourceType: "contextCompaction",
                status: "inProgress",
                itemID: "preview-context-compaction"
            ),
            replacesGroup: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .contextCompaction,
            groupName: "context-compaction",
            text: "Context automatically compacted",
            metadata: .init(
                sourceType: "contextCompaction",
                status: "completed",
                itemID: "preview-context-compaction"
            ),
            replacesGroup: true,
            delayBeforeFrameCount: compactionCompletionDelayFrameCount
        ),
        .init(
            kind: .toolCall,
            text: "File changes updated.",
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .rawReasoning,
            groupName: "raw-reasoning",
            text:
                "Need to avoid refreshing the finder client string until the user closes or clears the find bar. Appended text can wait for the next search session.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .rawReasoning,
            groupName: "raw-reasoning-follow-up",
            text:
                "I found the log update path and am keeping the current find session stable while new output streams in.\n",
            chunkByWord: true,
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
        .init(
            kind: .agentMessage,
            groupName: "agent-message-summary",
            text:
                "The preview stream now mixes commands, tool events, reasoning summaries, and visible assistant output instead of one repeated message kind.\n",
            delayBeforeFrameCount: interItemDelayFrameCount
        ),
    ]

    private static let previewStreamTimeline = streamTimeline(from: previewStreamTemplates)

    private static func makeCommandOutputPreviewLogEntries() -> [ReviewLogEntry] {
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
            .init(kind: .event, text: "Turn started: preview-command-output-panel"),
            .init(
                kind: .agentMessage,
                text: """
                    Checking the command output rendering path.

                    - Keep the transcript readable.
                    - Collapse terminal output by default.
                    - Expand into a bounded TextKit 2 scroll view.
                    """
            ),
            .init(
                kind: .command,
                groupID: "preview-command-output",
                text:
                    "$ xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj -scheme CodexReviewMonitor"
            ),
            .init(
                kind: .commandOutput,
                groupID: "preview-command-output",
                text: output,
                metadata: .init(
                    sourceType: "command",
                    title: "Ran command for 17s",
                    status: "succeeded",
                    exitCode: 0
                )
            ),
            .init(
                kind: .agentMessage,
                text: "The output remains available without taking over the whole log."
            ),
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

    private static func makeSidebarContent() -> (workspaces: [CodexReviewWorkspace], jobs: [CodexReviewJob]) {
        let now = Date()
        let workspacePaths = [
            "/path/to/workspace-alpha",
            "/path/to/workspace-beta",
            "/path/to/workspace-gamma",
        ]

        var workspaces: [CodexReviewWorkspace] = []
        var jobs: [CodexReviewJob] = []
        for (workspaceIndex, cwd) in workspacePaths.enumerated() {
            let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
            workspaces.append(CodexReviewWorkspace(cwd: cwd))
            jobs += makeJobDefinitions(for: workspaceName).enumerated().map { jobIndex, definition in
                makeJob(
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
                    lastAgentMessage: definition.lastAgentMessage,
                    logEntries: makePreviewLogEntries(for: definition, workspaceName: workspaceName)
                )
            }
        }
        return (workspaces, jobs)
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
        lastAgentMessage: String,
        logEntries: [ReviewLogEntry]
    ) -> CodexReviewJob {
        let job = CodexReviewJob.makeForTesting(
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
            lastAgentMessage: lastAgentMessage,
            logEntries: logEntries
        )
        seedPreviewTimeline(logEntries, in: job)
        return job
    }

    private static func seedPreviewTimeline(_ logEntries: [ReviewLogEntry], in job: CodexReviewJob) {
        for entry in logEntries {
            appendPreviewTimelineEntry(entry, to: job)
        }
    }

    private static func appendPreviewTimelineEntry(_ entry: ReviewLogEntry, to job: CodexReviewJob) {
        let itemID = ReviewTimelineItem.ID(rawValue: entry.groupID ?? entry.id.uuidString)
        let existingContent = entry.replacesGroup ? nil : job.timeline.item(for: itemID)?.content
        job.timeline.apply(
            .itemUpdated(
                .init(
                    id: itemID,
                    kind: previewTimelineKind(for: entry),
                    family: previewTimelineFamily(for: entry),
                    phase: previewTimelinePhase(for: entry),
                    content: previewTimelineContent(for: entry, existing: existingContent),
                    startedAt: entry.metadata?.startedAt,
                    completedAt: entry.metadata?.completedAt,
                    durationMs: entry.metadata?.durationMs
                )))
    }

    private static func previewTimelineKind(for entry: ReviewLogEntry) -> ReviewItemKind {
        switch entry.kind {
        case .command, .commandOutput:
            .commandExecution
        case .agentMessage:
            .agentMessage
        case .plan, .todoList:
            .plan
        case .reasoning, .reasoningSummary, .rawReasoning:
            .reasoning
        case .contextCompaction:
            .contextCompaction
        case .toolCall:
            .mcpToolCall
        case .diagnostic, .error, .progress, .event:
            ReviewItemKind(rawValue: entry.kind.rawValue)
        }
    }

    private static func previewTimelineFamily(for entry: ReviewLogEntry) -> ReviewItemFamily {
        switch entry.kind {
        case .command, .commandOutput:
            .command
        case .agentMessage:
            .message
        case .plan, .todoList:
            .plan
        case .reasoning, .reasoningSummary, .rawReasoning:
            .reasoning
        case .contextCompaction:
            .contextCompaction
        case .toolCall:
            .tool
        case .diagnostic, .error, .progress, .event:
            .diagnostic
        }
    }

    private static func previewTimelineContent(
        for entry: ReviewLogEntry,
        existing: ReviewTimelineItem.Content?
    ) -> ReviewTimelineItem.Content {
        switch entry.kind {
        case .command:
            return .command(
                .init(
                    command: previewCommandText(for: entry),
                    cwd: entry.metadata?.cwd,
                    output: "",
                    exitCode: entry.metadata?.exitCode,
                    status: previewCommandStatus(for: entry),
                    durationMs: entry.metadata?.durationMs
                ))
        case .commandOutput:
            let existingOutput: String
            let existingCommand: String?
            if case .command(let command) = existing {
                existingOutput = command.output
                existingCommand = command.command
            } else {
                existingOutput = ""
                existingCommand = nil
            }
            return .command(
                .init(
                    command: entry.metadata?.command ?? existingCommand ?? "Command",
                    cwd: entry.metadata?.cwd,
                    output: existingOutput + entry.text,
                    exitCode: entry.metadata?.exitCode,
                    status: previewCommandStatus(for: entry),
                    durationMs: entry.metadata?.durationMs
                ))
        case .agentMessage:
            return .message(.init(text: previewExistingText(existing, message: "") + entry.text))
        case .plan, .todoList:
            return .plan(.init(markdown: previewExistingText(existing, plan: "") + entry.text))
        case .reasoning:
            return .reasoning(.init(text: previewExistingText(existing, reasoning: "") + entry.text, style: .raw))
        case .reasoningSummary:
            return .reasoning(.init(text: previewExistingText(existing, reasoning: "") + entry.text, style: .summary))
        case .rawReasoning:
            return .reasoning(.init(text: previewExistingText(existing, reasoning: "") + entry.text, style: .raw))
        case .contextCompaction:
            return .contextCompaction(
                .init(
                    title: entry.text,
                    status: previewContextCompactionStatus(for: entry)
                ))
        case .toolCall:
            return .toolCall(
                .init(
                    result: entry.text,
                    status: previewToolCallStatus(for: entry)
                ))
        case .diagnostic, .error, .progress, .event:
            return .diagnostic(.init(message: previewExistingText(existing, diagnostic: "") + entry.text))
        }
    }

    private static func previewExistingText(
        _ content: ReviewTimelineItem.Content?,
        message defaultValue: String
    ) -> String {
        if case .message(let message) = content {
            return message.text
        }
        return defaultValue
    }

    private static func previewExistingText(
        _ content: ReviewTimelineItem.Content?,
        plan defaultValue: String
    ) -> String {
        if case .plan(let plan) = content {
            return plan.markdown
        }
        return defaultValue
    }

    private static func previewExistingText(
        _ content: ReviewTimelineItem.Content?,
        reasoning defaultValue: String
    ) -> String {
        if case .reasoning(let reasoning) = content {
            return reasoning.text
        }
        return defaultValue
    }

    private static func previewExistingText(
        _ content: ReviewTimelineItem.Content?,
        diagnostic defaultValue: String
    ) -> String {
        if case .diagnostic(let diagnostic) = content {
            return diagnostic.message
        }
        return defaultValue
    }

    private static func previewCommandText(for entry: ReviewLogEntry) -> String {
        if let command = entry.metadata?.command, command.isEmpty == false {
            return command
        }
        if entry.text.hasPrefix("$ ") {
            return String(entry.text.dropFirst(2))
        }
        return entry.text
    }

    private static func previewTimelinePhase(for entry: ReviewLogEntry) -> ReviewItemPhase {
        let status = entry.metadata?.commandStatus ?? entry.metadata?.status
        switch status {
        case "inProgress", "running", "started":
            return .running
        case "failed":
            return .failed
        case "cancelled":
            return .cancelled
        default:
            return entry.kind == .command ? .running : .completed
        }
    }

    private static func previewCommandStatus(for entry: ReviewLogEntry) -> ReviewCommandStatus? {
        guard let rawValue = entry.metadata?.commandStatus ?? entry.metadata?.status else {
            return nil
        }
        switch rawValue {
        case "succeeded", "success":
            return .completed
        default:
            return .init(rawValue: rawValue)
        }
    }

    private static func previewContextCompactionStatus(for entry: ReviewLogEntry) -> ReviewContextCompactionStatus? {
        guard let rawValue = entry.metadata?.status else {
            return nil
        }
        switch rawValue {
        case "inProgress", "running":
            return .inProgress
        case "completed", "succeeded", "success":
            return .completed
        default:
            return .init(rawValue: rawValue)
        }
    }

    private static func previewToolCallStatus(for entry: ReviewLogEntry) -> ReviewToolCallStatus? {
        guard let rawValue = entry.metadata?.status else {
            return nil
        }
        switch rawValue {
        case "inProgress", "running":
            return .inProgress
        case "completed", "succeeded", "success":
            return .completed
        case "failed":
            return .failed
        default:
            return .init(rawValue: rawValue)
        }
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

    private static func makePreviewLogEntries(
        for definition: PreviewJobDefinition,
        workspaceName: String
    ) -> [ReviewLogEntry] {
        switch definition.status {
        case .running:
            makeRunningPreviewLogEntries(for: definition, workspaceName: workspaceName)
        case .queued:
            [
                .init(kind: .event, text: "Queued review for \(definition.targetSummary)."),
                .init(kind: .progress, text: definition.summary),
            ]
        case .failed:
            [
                .init(kind: .event, text: "Turn started: preview-failed-\(workspaceName.lowercased())"),
                .init(
                    kind: .command,
                    groupID: "preview-failed-command-\(workspaceName)-\(definition.targetSummary)",
                    text: "$ /bin/zsh -lc \"swift test --build-system swiftbuild --no-parallel\""
                ),
                .init(
                    kind: .commandOutput,
                    groupID: "preview-failed-command-\(workspaceName)-\(definition.targetSummary)",
                    text: """
                        Building for debugging...
                        Test Suite 'ReviewUITests' started.
                        ReviewMonitorContentPreviewTests.testPreviewStore failed: expected command output panel metadata.
                        """,
                    metadata: .init(
                        sourceType: "command",
                        title: "Ran command for 10s",
                        status: "failed",
                        exitCode: 1
                    )
                ),
                .init(kind: .error, text: definition.summary),
                .init(kind: .agentMessage, text: definition.lastAgentMessage),
            ]
        case .cancelled:
            [
                .init(kind: .event, text: "Turn started: preview-cancelled-\(workspaceName.lowercased())"),
                .init(kind: .progress, text: definition.summary),
                .init(kind: .agentMessage, text: definition.lastAgentMessage),
            ]
        case .succeeded:
            [
                .init(kind: .event, text: "Turn started: preview-complete-\(workspaceName.lowercased())"),
                .init(
                    kind: .command,
                    groupID: "preview-complete-command-\(workspaceName)-\(definition.targetSummary)",
                    text: "$ /bin/zsh -lc \"swift test --filter ReviewUI\""
                ),
                .init(
                    kind: .commandOutput,
                    groupID: "preview-complete-command-\(workspaceName)-\(definition.targetSummary)",
                    text: """
                        Test Suite 'ReviewUITests' started.
                        Test commandOutputRendersCollapsedTextKitPanelAndExpandsInline passed.
                        Test Suite 'ReviewUITests' passed.
                        """,
                    metadata: .init(
                        sourceType: "command",
                        title: "Ran command for 4s",
                        status: "succeeded",
                        exitCode: 0
                    )
                ),
                .init(
                    kind: .reasoningSummary,
                    groupID: "preview-complete-summary-\(workspaceName)-\(definition.targetSummary)",
                    text: definition.summary
                ),
                .init(kind: .agentMessage, text: definition.lastAgentMessage),
            ]
        }
    }

    private static func makeRunningPreviewLogEntries(
        for definition: PreviewJobDefinition,
        workspaceName: String
    ) -> [ReviewLogEntry] {
        let sourceReadGroupID = "preview-initial-source-read-\(workspaceName)-\(definition.targetSummary)"
        let sourceReadCommand =
            "sed -n '1,260p' Sources/ReviewUI/Detail/ReviewMonitorCommandOutputDisplayDocument.swift"
        return [
            .init(kind: .event, text: "Turn started: preview-\(workspaceName.lowercased())"),
            .init(kind: .progress, text: "Reviewing \(definition.targetSummary)"),
            .init(
                kind: .contextCompaction,
                groupID: "preview-initial-context-compaction-\(workspaceName)-\(definition.targetSummary)",
                replacesGroup: true,
                text: "Context automatically compacted",
                metadata: .init(
                    sourceType: "contextCompaction",
                    status: "completed",
                    itemID: "preview-initial-context-compaction-\(workspaceName)-\(definition.targetSummary)"
                )
            ),
            .init(
                kind: .plan,
                groupID: "preview-initial-plan-\(workspaceName)-\(definition.targetSummary)",
                replacesGroup: true,
                text: """
                    [completed] Inspect changed files
                    [in_progress] Check ReviewMonitor log behavior
                    [pending] Run focused tests
                    """
            ),
            .init(
                kind: .command,
                groupID: "preview-initial-command-\(workspaceName)-\(definition.targetSummary)",
                text: "$ /bin/zsh -lc \"git diff --stat && rg -n 'ReviewMonitor' Sources Tests\""
            ),
            .init(
                kind: .commandOutput,
                groupID: "preview-initial-command-\(workspaceName)-\(definition.targetSummary)",
                text: """
                    Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift | 34 +++++++++++++++++
                    Sources/ReviewUI/Detail/ReviewMonitorLogDocumentView.swift | 18 ++++++++--
                    Tests/ReviewUITests/ReviewUITests.swift | 12 ++++++

                    Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift:42: private let logDocumentView = ReviewMonitorLogDocumentView()
                    Tests/ReviewUITests/ReviewUITests.swift:2322: commandOutputRendersCollapsedTextKitPanelAndExpandsInline
                    """,
                metadata: .init(
                    sourceType: "command",
                    title: "Ran command for 6s",
                    status: "succeeded",
                    exitCode: 0
                )
            ),
            .init(
                kind: .command,
                groupID: sourceReadGroupID,
                text: "$ /bin/zsh -lc \"\(sourceReadCommand)\"",
                metadata: .init(
                    sourceType: "commandExecution",
                    status: "inProgress",
                    itemID: sourceReadGroupID,
                    command: "/bin/zsh -lc \"\(sourceReadCommand)\"",
                    startedAt: Date().addingTimeInterval(-88),
                    commandActions: [
                        .init(
                            kind: .read,
                            command: sourceReadCommand,
                            name: "ReviewMonitorCommandOutputDisplayDocument.swift",
                            path: "Sources/ReviewUI/Detail/ReviewMonitorCommandOutputDisplayDocument.swift"
                        )
                    ],
                    commandStatus: "inProgress"
                ),
            ),
            .init(kind: .toolCall, text: "MCP codex_review.review_start started."),
            .init(
                kind: .reasoningSummary,
                groupID: "preview-initial-summary-\(workspaceName)-\(definition.targetSummary)",
                text:
                    "I am comparing the current UI state with the streaming log updates before changing the finder integration."
            ),
            .init(
                kind: .agentMessage,
                groupID: "preview-initial-agent-\(workspaceName)-\(definition.targetSummary)",
                text: definition.lastAgentMessage
            ),
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
