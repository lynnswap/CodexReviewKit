import Foundation
@_spi(Testing) import CodexReview

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
        let chunkByWord: Bool
        let delayAfterPreviousTicks: Int
        let chunkIntervalTicks: Int

        init(
            kind: ReviewLogEntry.Kind,
            groupName: String? = nil,
            text: String,
            chunkByWord: Bool = false,
            delayAfterPreviousTicks: Int,
            chunkIntervalTicks: Int = 1
        ) {
            self.kind = kind
            self.groupName = groupName
            self.text = text
            self.chunkByWord = chunkByWord
            self.delayAfterPreviousTicks = delayAfterPreviousTicks
            self.chunkIntervalTicks = chunkIntervalTicks
        }
    }

    private struct PreviewStreamStep {
        let kind: ReviewLogEntry.Kind
        let groupName: String?
        let text: String
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
        streamInterval: Duration = .milliseconds(40)
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
        store.previewSupportRetainer = PreviewLogStreamer(
            store: store,
            interval: streamInterval
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
                job.appendLogEntry(streamEntry(from: frame.step, for: job, cycle: frame.cycle))
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
        return .init(
            kind: step.kind,
            groupID: step.groupName.map { "preview-\($0)-\(job.id)-\(cycle)" },
            text: step.text
        )
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
            let delay = timeline.isEmpty ? 1 : max(1, template.delayAfterPreviousTicks)
            if delay > 1 {
                timeline.append(contentsOf: Array(repeating: nil, count: delay - 1))
            }
            let chunks = template.chunkByWord ? wordChunks(in: template.text) : [template.text]
            for (index, chunk) in chunks.enumerated() {
                if index > 0 && template.chunkIntervalTicks > 1 {
                    timeline.append(contentsOf: Array(repeating: nil, count: template.chunkIntervalTicks - 1))
                }
                timeline.append(PreviewStreamStep(
                    kind: template.kind,
                    groupName: template.groupName,
                    text: chunk
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

    private static let interItemDelayFrameCount = 13
    private static let previewJobTickOffset = 7

    private static let previewStreamTemplates: [PreviewStreamTemplate] = [
        .init(
            kind: .event,
            text: "Turn started: \(previewTurnID(1))",
            delayAfterPreviousTicks: 1
        ),
        .init(
            kind: .plan,
            groupName: "plan",
            text: """
            [completed] Inspect ReviewMonitor log rendering
            [in_progress] Preserve active find UI while streaming
            [pending] Run focused UI tests
            """,
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .command,
            text: "$ /bin/zsh -lc \"rg -n 'ReviewMonitorLog' Sources/ReviewUI && swift test --filter ReviewUI\"",
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .toolCall,
            text: "MCP codex_review.review_read started.",
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .reasoningSummary,
            groupName: "reasoning-summary",
            text: "Checking whether append-only log updates are notifying NSTextFinder while an incremental search is active.\n",
            chunkByWord: true,
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .command,
            text: "$ /bin/zsh -lc \"sed -n '1,240p' Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift\"",
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .toolCall,
            text: "File changes updated.",
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .rawReasoning,
            groupName: "raw-reasoning",
            text: "Need to avoid refreshing the finder client string until the user closes or clears the find bar. Appended text can wait for the next search session.\n",
            chunkByWord: true,
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .agentMessage,
            groupName: "agent-message-main",
            text: "I found the log update path and am keeping the current find session stable while new output streams in.\n",
            chunkByWord: true,
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
        .init(
            kind: .agentMessage,
            groupName: "agent-message-summary",
            text: "The preview stream now mixes commands, tool events, reasoning summaries, and visible assistant output instead of one repeated message kind.\n",
            chunkByWord: true,
            delayAfterPreviousTicks: interItemDelayFrameCount
        ),
    ]

    private static let previewStreamTimeline = streamTimeline(from: previewStreamTemplates)

    @_spi(PreviewSupport)
    public static func makePreviewAccounts() -> [CodexAccount] {
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
    ) -> CodexAccount {
        let account = CodexAccount(email: email, planType: "pro")
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

    static func makePreviewSettingsSnapshot() -> CodexReviewSettingsSnapshot {
        .init(
            model: "gpt-5.4",
            reasoningEffort: .medium,
            serviceTier: .fast,
            models: makePreviewModelCatalog()
        )
    }

    static func makePreviewModelCatalog() -> [CodexReviewModelCatalogItem] {
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
            lastAgentMessage: lastAgentMessage,
            logEntries: logEntries
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
                    body: "The preview should make the first workspace show structured review findings as soon as it is selected.",
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
            [
                .init(kind: .event, text: "Turn started: preview-\(workspaceName.lowercased())"),
                .init(kind: .progress, text: "Reviewing \(definition.targetSummary)"),
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
                    text: "$ /bin/zsh -lc \"git diff --stat && rg -n 'ReviewMonitor' Sources Tests\""
                ),
                .init(kind: .toolCall, text: "MCP codex_review.review_start started."),
                .init(
                    kind: .reasoningSummary,
                    groupID: "preview-initial-summary-\(workspaceName)-\(definition.targetSummary)",
                    text: "I am comparing the current UI state with the streaming log updates before changing the finder integration."
                ),
                .init(
                    kind: .agentMessage,
                    groupID: "preview-initial-agent-\(workspaceName)-\(definition.targetSummary)",
                    text: definition.lastAgentMessage
                ),
            ]
        case .queued:
            [
                .init(kind: .event, text: "Queued review for \(definition.targetSummary)."),
                .init(kind: .progress, text: definition.summary),
            ]
        case .failed:
            [
                .init(kind: .event, text: "Turn started: preview-failed-\(workspaceName.lowercased())"),
                .init(kind: .command, text: "$ /bin/zsh -lc \"swift test --build-system swiftbuild --no-parallel\""),
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
                .init(kind: .command, text: "$ /bin/zsh -lc \"swift test --filter ReviewUI\""),
                .init(
                    kind: .reasoningSummary,
                    groupID: "preview-complete-summary-\(workspaceName)-\(definition.targetSummary)",
                    text: definition.summary
                ),
                .init(kind: .agentMessage, text: definition.lastAgentMessage),
            ]
        }
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
