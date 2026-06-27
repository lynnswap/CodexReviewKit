import AppKit
import CodexKit
import CodexReviewKit
import ObservationBridge
import ReviewMonitorRendering

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private enum LogRenderTarget: Equatable {
        case job(String)
        case chat(CodexThreadID)
    }

    private let codexModelSource: ReviewMonitorCodexModelSource?
    private let uiState: ReviewMonitorUIState
    private let store: CodexReviewStore
    private let selectedCodexChat: ReviewMonitorSelectedCodexChat
    private let logScrollView = ReviewMonitorLogScrollView()
    private var logRenderer = ReviewMonitorLogRenderer()
    #if DEBUG
        private var previewTimelineLogProjection = ReviewMonitorTimelineLogProjection()
    #endif
    private let workspaceFindingsView = ReviewMonitorWorkspaceFindingsView()
    private let placeholderViewController = PlaceholderViewController()
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private var selectionObservation: PortableObservationTracking.Token?
    private var selectedJobObservation: PortableObservationTracking.Token?
    private var selectedWorkspaceFindingsObservation: PortableObservationTracking.Token?
    private var selectedCodexChatLogTask: Task<Void, Never>?
    private var boundJob: CodexReviewJob?
    private var boundChatID: CodexThreadID?
    private var boundWorkspaceSection: ReviewMonitorWorkspaceSectionSelection?
    private var displayedSelection: ReviewMonitorSelectionID?
    private var logScrollTargetsByJobID: [String: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
    private var logRenderTask: Task<Void, Never>?
    private var logRenderGeneration: UInt64 = 0
    private var appliedLogRenderGeneration: UInt64 = 0
    private var hasAppliedBoundLog = false

    convenience init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        modelContext: CodexModelContext
    ) {
        self.init(
            store: store,
            uiState: uiState,
            codexModelSource: ReviewMonitorCodexModelSource(modelContext: modelContext)
        )
    }

    init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        codexModelSource: ReviewMonitorCodexModelSource? = nil
    ) {
        self.codexModelSource = codexModelSource
        self.store = store
        self.uiState = uiState
        self.selectedCodexChat = ReviewMonitorSelectedCodexChat(modelSource: codexModelSource)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        selectionObservation?.cancel()
        selectedJobObservation?.cancel()
        selectedWorkspaceFindingsObservation?.cancel()
        selectedCodexChatLogTask?.cancel()
        logRenderTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        bindObservation()
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard performDisplayedTextFinderAction(sender) else {
            super.performTextFinderAction(sender)
            return
        }
    }

    private func configureHierarchy() {
        let safeArea = view.safeAreaLayoutGuide
        let placeholderView = placeholderViewController.view
        addChild(placeholderViewController)
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logScrollView)
        view.addSubview(workspaceFindingsView)
        view.addSubview(placeholderView)

        displayedContentConstraints = [
            logScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ]

        NSLayoutConstraint.activate(
            displayedContentConstraints
                + [
                    workspaceFindingsView.topAnchor.constraint(equalTo: view.topAnchor),
                    workspaceFindingsView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                    workspaceFindingsView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                    workspaceFindingsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                    placeholderView.topAnchor.constraint(equalTo: view.topAnchor),
                    placeholderView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                    placeholderView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                    placeholderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ]
        )
    }

    private func bindObservation() {
        selectionObservation?.cancel()
        selectionObservation = withPortableContinuousObservation { [weak self, uiState] event in
            let selection = uiState.selection
            guard let self else {
                return
            }
            guard event.kind == .initial || self.selectionRequiresPresentationUpdate(selection) else {
                return
            }
            self.updatePresentation(selection: selection)
        }
    }

    private func selectionRequiresPresentationUpdate(_ selection: ReviewMonitorSelection?) -> Bool {
        switch selection {
        case .job(let selectedJob):
            return boundJob !== selectedJob || displayedSelection != selection?.id
        case .workspaceSection(let selectedSection):
            return boundWorkspaceSection != selectedSection || displayedSelection != selection?.id
        case .workspace, .chat:
            return displayedSelection != selection?.id
        case nil:
            return displayedSelection != nil
        }
    }

    private func updatePresentation(selection: ReviewMonitorSelection?) {
        switch selection {
        case .job(let selectedJob):
            clearDisplayedWorkspace()
            displayJob(selectedJob)
            hidePlaceholder()
            logScrollView.isHidden = false
            workspaceFindingsView.isHidden = true
            displayedSelection = selection?.id

        case .workspaceSection(let selectedSection):
            clearDisplayedLogSelection()
            displayWorkspaceSection(selectedSection)
            logScrollView.isHidden = true
            displayedSelection = selection?.id

        case .workspace:
            clearDisplayedLogSelection()
            clearDisplayedWorkspace()
            displayPlaceholder(.noFindings)
            logScrollView.isHidden = true
            workspaceFindingsView.isHidden = true
            displayedSelection = selection?.id

        case .chat:
            clearDisplayedLogSelection()
            clearDisplayedWorkspace()
            if case .chat(let selectedChat) = selection {
                displayChat(selectedChat)
            }
            hidePlaceholder()
            logScrollView.isHidden = false
            workspaceFindingsView.isHidden = true
            displayedSelection = selection?.id

        case nil:
            clearDisplayedLogSelection()
            clearDisplayedWorkspace()
            displayPlaceholder(.noSelection)
            logScrollView.isHidden = true
            workspaceFindingsView.isHidden = true
            displayedSelection = nil
        }
    }

    private func displayJob(_ selectedJob: CodexReviewJob) {
        let isSwitchingRenderedJob = boundJob != nil && boundJob !== selectedJob
        cacheBoundJobScrollTarget()
        if isSwitchingRenderedJob {
            logScrollView.resetFindStateForContentReuse()
        }
        selectedJobObservation?.cancel()
        selectedJobObservation = nil
        selectedCodexChatLogTask?.cancel()
        selectedCodexChatLogTask = nil
        boundChatID = nil
        resetLogRenderer()
        boundJob = selectedJob
        selectedCodexChat.bind(to: selectedJob.reviewChatIdentity)
        #if DEBUG
            guard codexModelSource?.modelContext != nil else {
                renderPreviewJobTimeline(
                    selectedJob,
                    restoring: restorationTarget(selectedJob),
                    allowIncrementalUpdate: false
                )
                selectedJobObservation = withPortableContinuousObservation { [weak self] _ in
                    guard let self,
                        self.boundJob === selectedJob
                    else {
                        return
                    }
                    _ = self.codexModelSource?.generation
                    if self.codexModelSource?.modelContext != nil {
                        self.displayJob(selectedJob)
                        return
                    }
                    _ = selectedJob.timeline.revision
                    self.renderPreviewJobTimeline(
                        selectedJob,
                        restoring: self.logScrollView.currentScrollRestorationTarget,
                        allowIncrementalUpdate: true
                    )
                }
                return
            }
        #endif
        startSelectedCodexChatLogStream(
            target: .job(selectedJob.id),
            initialRestorationTarget: restorationTarget(selectedJob)
        )

        selectedJobObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self,
                self.boundJob === selectedJob
            else {
                return
            }
            self.selectedCodexChat.bind(to: selectedJob.reviewChatIdentity)
        }
    }

    #if DEBUG
        @discardableResult
        private func renderPreviewJobTimeline(
            _ selectedJob: CodexReviewJob,
            restoring restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
            allowIncrementalUpdate: Bool
        ) -> Bool {
            let timelineDocument = ReviewTimelineDocumentRenderer().document(from: selectedJob.timeline)
            let sourceDocument = previewTimelineLogProjection.render(timelineDocument: timelineDocument)
            return renderBoundLog(
                sourceDocument: sourceDocument,
                target: .job(selectedJob.id),
                restorationTarget: restorationTarget,
                allowIncrementalUpdate: allowIncrementalUpdate && hasAppliedBoundLog
            )
        }
    #endif

    private func displayChat(_ selectedChat: ReviewMonitorCodexSidebarSnapshot.Chat) {
        if boundChatID != selectedChat.id {
            logScrollView.resetFindStateForContentReuse()
        }
        selectedCodexChatLogTask?.cancel()
        selectedCodexChatLogTask = nil
        resetLogRenderer()
        boundChatID = selectedChat.id
        selectedCodexChat.bind(toChatID: selectedChat.id)
        startSelectedCodexChatLogStream(target: .chat(selectedChat.id), initialRestorationTarget: .bottom)
    }

    private func clearDisplayedLogSelection() {
        cacheBoundJobScrollTarget()
        selectedJobObservation?.cancel()
        selectedJobObservation = nil
        selectedCodexChatLogTask?.cancel()
        selectedCodexChatLogTask = nil
        boundJob = nil
        boundChatID = nil
        selectedCodexChat.unbind()
        resetLogRenderer()
        logScrollView.resetFindStateForContentReuse()
        logScrollView.clear()
    }

    private func displayWorkspaceSection(_ section: ReviewMonitorWorkspaceSectionSelection) {
        if boundWorkspaceSection != section {
            selectedWorkspaceFindingsObservation?.cancel()
            selectedWorkspaceFindingsObservation = nil
            boundWorkspaceSection = section
            bindWorkspaceSectionObservation(section)
        }
    }

    private func clearDisplayedWorkspace() {
        selectedWorkspaceFindingsObservation?.cancel()
        selectedWorkspaceFindingsObservation = nil
        boundWorkspaceSection = nil
        workspaceFindingsView.clear()
        workspaceFindingsView.isHidden = true
    }

    private func bindWorkspaceSectionObservation(_ section: ReviewMonitorWorkspaceSectionSelection) {
        selectedWorkspaceFindingsObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self,
                self.boundWorkspaceSection?.id == section.id
            else {
                return
            }
            let entries = self.workspaceFindingEntries(for: self.currentWorkspaces(for: section))
            self.renderWorkspaceFindings(entries: entries)
        }
    }

    @discardableResult
    private func renderWorkspaceFindings(entries: [ReviewMonitorWorkspaceFindingsView.Entry]) -> Bool {
        let rendered = workspaceFindingsView.render(entries: entries)
        let presentationChanged = updateWorkspaceFindingsPresentation(hasFindings: entries.isEmpty == false)
        return rendered || presentationChanged
    }

    @discardableResult
    private func updateWorkspaceFindingsPresentation(hasFindings: Bool) -> Bool {
        if hasFindings {
            let placeholderChanged = hidePlaceholder()
            let findingsChanged = workspaceFindingsView.isHidden
            workspaceFindingsView.isHidden = false
            return placeholderChanged || findingsChanged
        }

        let findingsChanged = workspaceFindingsView.isHidden == false
        workspaceFindingsView.isHidden = true
        return displayPlaceholder(.noFindings) || findingsChanged
    }

    @discardableResult
    private func displayPlaceholder(_ content: PlaceholderContent) -> Bool {
        let contentChanged = placeholderViewController.render(content: content)
        let hiddenChanged = placeholderViewController.view.isHidden
        placeholderViewController.view.isHidden = false
        return contentChanged || hiddenChanged
    }

    @discardableResult
    private func hidePlaceholder() -> Bool {
        let hiddenChanged = placeholderViewController.view.isHidden == false
        placeholderViewController.view.isHidden = true
        return hiddenChanged
    }

    private func workspaceFindingEntries(
        for workspaces: [CodexReviewWorkspace]
    ) -> [ReviewMonitorWorkspaceFindingsView.Entry] {
        workspaces.flatMap { workspace in
            workspaceFindingEntries(in: workspace)
        }
    }

    private func workspaceFindingEntries(
        in workspace: CodexReviewWorkspace
    ) -> [ReviewMonitorWorkspaceFindingsView.Entry] {
        store.orderedJobs(in: workspace).flatMap { job -> [ReviewMonitorWorkspaceFindingsView.Entry] in
            guard let result = job.core.output.reviewResult,
                result.state == .hasFindings
            else {
                return []
            }
            let threadID = workspaceFindingThreadID(for: job)
            return result.findings.map { finding in
                ReviewMonitorWorkspaceFindingsView.Entry(
                    threadID: threadID,
                    targetSummary: job.targetSummary,
                    priority: finding.priority,
                    title: finding.title,
                    body: finding.body,
                    locationText: locationText(for: finding.location, in: workspace)
                )
            }
        }
    }

    private func currentWorkspaces(
        for section: ReviewMonitorWorkspaceSectionSelection
    ) -> [CodexReviewWorkspace] {
        let workspacesByCWD = Dictionary(
            uniqueKeysWithValues: store.orderedWorkspaces.map { ($0.cwd, $0) }
        )
        return section.workspaceCWDs.compactMap { workspacesByCWD[$0] }
    }

    private func locationText(
        for location: ParsedReviewResult.Finding.Location?,
        in workspace: CodexReviewWorkspace
    ) -> String? {
        guard let location else {
            return nil
        }

        let path: String
        if let relativePath = workspaceRelativePath(location.path, in: workspace) {
            path = relativePath
        } else {
            path = location.path
        }
        return "\(path):\(location.startLine)-\(location.endLine)"
    }

    private func workspaceRelativePath(
        _ path: String,
        in workspace: CodexReviewWorkspace
    ) -> String? {
        guard path.hasPrefix("/"), workspace.cwd.hasPrefix("/") else {
            return nil
        }
        let workspaceURL = standardizedFileURL(workspace.cwd, isDirectory: true)
        let fileURL = standardizedFileURL(path, isDirectory: false)
        let workspaceComponents = workspaceURL.pathComponents
        let fileComponents = fileURL.pathComponents
        guard fileComponents.count > workspaceComponents.count,
            fileComponents.starts(with: workspaceComponents)
        else {
            return nil
        }
        return
            fileComponents
            .dropFirst(workspaceComponents.count)
            .joined(separator: "/")
    }

    private func standardizedFileURL(_ path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func workspaceFindingThreadID(for job: CodexReviewJob) -> String {
        if let reviewThreadID = nonEmptyID(job.core.run.reviewThreadID) {
            return reviewThreadID
        }
        if let threadID = nonEmptyID(job.core.run.threadID) {
            return threadID
        }
        return job.id
    }

    private func nonEmptyID(_ id: String?) -> String? {
        guard let id else {
            return nil
        }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func renderBoundLog(
        sourceDocument: ReviewMonitorLog.Document,
        target: LogRenderTarget,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        logRenderGeneration &+= 1
        let generation = logRenderGeneration
        let renderer = logRenderer
        logRenderTask?.cancel()
        logRenderTask = Task { @MainActor [weak self] in
            let renderedDocument = await renderer.render(sourceDocument: sourceDocument)
            guard Task.isCancelled == false,
                let self,
                self.logRenderGeneration == generation,
                self.isCurrentLogRenderTarget(target)
            else {
                return
            }
            _ = self.logScrollView.render(
                sourceDocument: renderedDocument.source,
                displayDocument: renderedDocument.display,
                restoring: restorationTarget,
                allowIncrementalUpdate: allowIncrementalUpdate && self.hasAppliedBoundLog
            )
            self.appliedLogRenderGeneration = generation
            self.hasAppliedBoundLog = true
        }
        return true
    }

    private func startSelectedCodexChatLogStream(
        target: LogRenderTarget,
        initialRestorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget
    ) {
        selectedCodexChatLogTask?.cancel()
        let stream = selectedCodexChat.logSourceChangeStream()
        selectedCodexChatLogTask = Task { @MainActor [weak self] in
            var didRenderInitialDocument = false
            for await change in stream {
                guard let self,
                    self.isCurrentLogRenderTarget(target)
                else {
                    return
                }
                self.applySelectedCodexChatLogChange(
                    change,
                    target: target,
                    restorationTarget: didRenderInitialDocument
                        ? self.logScrollView.currentScrollRestorationTarget
                        : initialRestorationTarget,
                    allowIncrementalUpdate: didRenderInitialDocument && change.allowsIncrementalRender
                )
                if change.sourceDocument != nil {
                    didRenderInitialDocument = true
                }
            }
        }
    }

    private func applySelectedCodexChatLogChange(
        _ change: ReviewMonitorLogSourceChange,
        target: LogRenderTarget,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) {
        guard let document = change.sourceDocument else {
            resetLogRenderer()
            logScrollView.clear()
            return
        }
        renderBoundLog(
            sourceDocument: document,
            target: target,
            restorationTarget: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
    }

    private func isCurrentLogRenderTarget(_ target: LogRenderTarget) -> Bool {
        switch target {
        case .job(let id):
            boundJob?.id == id
        case .chat(let id):
            boundChatID == id
        }
    }

    private func cacheBoundJobScrollTarget() {
        guard let boundJob else {
            return
        }
        logScrollTargetsByJobID[boundJob.id] = logScrollView.currentScrollRestorationTarget
    }

    private func resetLogRenderer() {
        logRenderTask?.cancel()
        logRenderTask = nil
        logRenderGeneration &+= 1
        appliedLogRenderGeneration = logRenderGeneration
        hasAppliedBoundLog = false
        logRenderer = ReviewMonitorLogRenderer()
        #if DEBUG
            previewTimelineLogProjection = ReviewMonitorTimelineLogProjection()
        #endif
    }

    private func restorationTarget(
        _ job: CodexReviewJob
    ) -> ReviewMonitorLogScrollView.ScrollRestorationTarget {
        return logScrollTargetsByJobID[job.id] ?? .bottom
    }

    @discardableResult
    func performDisplayedTextFinderAction(_ sender: Any?) -> Bool {
        switch displayedSelection {
        case .job:
            return logScrollView.performDisplayedTextFinderAction(sender)
        case .workspaceSection:
            return workspaceFindingsView.performDisplayedTextFinderAction(sender)
        case .chat:
            return logScrollView.performDisplayedTextFinderAction(sender)
        case .workspace, nil:
            return false
        }
    }

    func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch displayedSelection {
        case .job:
            return logScrollView.validateDisplayedTextFinderAction(item)
        case .workspaceSection:
            return workspaceFindingsView.validateDisplayedTextFinderAction(item)
        case .chat:
            return logScrollView.validateDisplayedTextFinderAction(item)
        case .workspace, nil:
            return false
        }
    }

}

#if DEBUG
    @MainActor
    extension ReviewMonitorTransportViewController {
        struct RenderSnapshotForTesting: Sendable, Equatable {
            let title: String?
            let summary: String?
            let log: String
            let isShowingEmptyState: Bool
        }

        struct WorkspaceFindingSnapshotForTesting: Sendable, Equatable {
            let text: String
            let isShowingNoFindingsState: Bool
            let isShowingFindingsList: Bool
        }

        enum DisplayedSelectionForTesting: Sendable, Equatable {
            case job(String)
            case workspaceSection(String)
            case workspace(String)
            case chat(String)
        }

        struct RenderedStateForTesting: Sendable, Equatable {
            let snapshot: RenderSnapshotForTesting
            let selection: DisplayedSelectionForTesting?
        }

        var selectionObservationForTesting: PortableObservationTracking.Token? {
            selectionObservation
        }

        var selectedJobObservationForTesting: PortableObservationTracking.Token? {
            selectedJobObservation
        }

        var selectedWorkspaceFindingsObservationForTesting: PortableObservationTracking.Token? {
            selectedWorkspaceFindingsObservation
        }

        var selectedCodexChatReviewIdentityForTesting: CodexReviewIdentity? {
            selectedCodexChat.identity
        }

        var selectedCodexChatIDForTesting: String? {
            selectedCodexChat.chat?.id.rawValue
        }

        var selectedCodexChatPhaseForTesting: CodexDataPhase {
            selectedCodexChat.phase
        }

        var selectedCodexChatItemTextsForTesting: [String] {
            selectedCodexChat.chat?.items.compactMap(\.text) ?? []
        }

        var observationForExpectedRenderedStateForTesting: PortableObservationTracking.Token? {
            let expectedSelection = expectedRenderedStateForTesting.selection
            if displayedSelectionForTesting != expectedSelection {
                return selectionObservation
            }
            switch expectedSelection {
            case .job:
                return selectedJobObservation ?? selectionObservation
            case .workspaceSection:
                return selectedWorkspaceFindingsObservation ?? selectionObservation
            case .workspace, .chat:
                return selectionObservation
            case nil:
                return selectionObservation
            }
        }

        var displayedTitleForTesting: String? {
            nil
        }

        var displayedLogForTesting: String {
            logScrollView.displayedTextForTesting
        }

        var displayedWorkspaceFindingsForTesting: String {
            workspaceFindingsView.displayedTextForTesting
        }

        var displayedSummaryForTesting: String? {
            nil
        }

        var isShowingEmptyStateForTesting: Bool {
            placeholderViewController.view.isHidden == false && placeholderViewController.content == .noSelection
        }

        var emptyStateFrameForTesting: NSRect {
            placeholderViewController.view.frame
        }

        var isShowingNoFindingsStateForTesting: Bool {
            placeholderViewController.view.isHidden == false && placeholderViewController.content == .noFindings
        }

        var isShowingWorkspaceFindingsListForTesting: Bool {
            workspaceFindingsView.isShowingFindingsListForTesting
        }

        var logAppendCountForTesting: Int {
            logScrollView.appendCount
        }

        var logReplaceCountForTesting: Int {
            logScrollView.replaceCount
        }

        var logReloadCountForTesting: Int {
            logScrollView.reloadCount
        }

        var logAutoFollowCountForTesting: Int {
            logScrollView.autoFollowCount
        }

        var logWordGlowCountForTesting: Int {
            logScrollView.wordGlowCountForTesting
        }

        var logWordFadeRenderingAttributeRangeCountForTesting: Int {
            logScrollView.wordFadeRenderingAttributeRangeCountForTesting
        }

        var logWordFadeStorageUsesOpaqueTextColorForTesting: Bool {
            logScrollView.wordFadeStorageUsesOpaqueTextColorForTesting
        }

        var logWordFadeDisplayInvalidationCountForTesting: Int {
            logScrollView.wordFadeDisplayInvalidationCountForTesting
        }

        var logCommandOutputPanelCountForTesting: Int {
            logScrollView.commandOutputPanelCountForTesting
        }

        var logTerminalDecorationRectCountForTesting: Int {
            logScrollView.terminalDecorationRectCountForTesting
        }

        var logExpandedCommandOutputPanelCountForTesting: Int {
            logScrollView.expandedCommandOutputPanelCountForTesting
        }

        var logCommandOutputPanelUsesTextKit2ForTesting: Bool {
            logScrollView.commandOutputPanelUsesTextKit2ForTesting
        }

        var logCommandOutputPanelUsesInlineAttachmentForTesting: Bool {
            logScrollView.commandOutputPanelUsesInlineAttachmentForTesting
        }

        var logCommandOutputPanelUsesButtonAttachmentForTesting: Bool {
            logScrollView.commandOutputPanelUsesButtonAttachmentForTesting
        }

        var logCollapsedCommandOutputPanelAttachmentLineHeightForTesting: CGFloat? {
            logScrollView.collapsedCommandOutputPanelAttachmentLineHeightForTesting
        }

        var logCollapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting: Bool {
            logScrollView.collapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting
        }

        var logCommandOutputPanelUsesSystemMaterialBackgroundForTesting: Bool {
            logScrollView.commandOutputPanelUsesSystemMaterialBackgroundForTesting
        }

        var logCommandOutputPanelVisibleLineCapacityForTesting: Int {
            logScrollView.commandOutputPanelVisibleLineCapacityForTesting
        }

        var logCommandOutputPanelResultTextForTesting: String? {
            logScrollView.commandOutputPanelResultTextForTesting
        }

        var logCommandOutputPanelTerminalTextForTesting: String? {
            logScrollView.commandOutputPanelTerminalTextForTesting
        }

        func logCommandOutputPanelTerminalTextForTesting(blockID: ReviewMonitorLog.BlockID) -> String? {
            logScrollView.commandOutputPanelTerminalTextForTesting(blockID: blockID)
        }

        var logCommandOutputPanelCommandLineTextForTesting: String? {
            logScrollView.commandOutputPanelCommandLineTextForTesting
        }

        var logCommandOutputPanelOutputScrollTextForTesting: String? {
            logScrollView.commandOutputPanelOutputScrollTextForTesting
        }

        var logCommandOutputPanelOutputScrollIsScrollableForTesting: Bool {
            logScrollView.commandOutputPanelOutputScrollIsScrollableForTesting
        }

        var logCommandOutputPanelOutputScrollUsesHorizontalScrollingForTesting: Bool {
            logScrollView.commandOutputPanelOutputScrollUsesHorizontalScrollingForTesting
        }

        var logCommandOutputPanelOutputScrollVerticalOffsetForTesting: CGFloat? {
            logScrollView.commandOutputPanelOutputScrollVerticalOffsetForTesting
        }

        var logCommandOutputPanelOutputScrollMaximumVerticalOffsetForTesting: CGFloat? {
            logScrollView.commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting
        }

        func scrollCommandOutputPanelOutputForTesting(deltaY: CGFloat) -> Bool {
            logScrollView.scrollCommandOutputPanelOutputForTesting(deltaY: deltaY)
        }

        var logCommandOutputPanelOutputHitTestTargetsTextViewForTesting: Bool {
            logScrollView.commandOutputPanelOutputHitTestTargetsTextViewForTesting
        }

        func logFinderRectsForTesting(_ range: NSRange) -> [NSRect] {
            logScrollView.finderRectsForTesting(range)
        }

        var logFirstCommandOutputPanelRectForTesting: NSRect? {
            logScrollView.firstCommandOutputPanelRectForTesting
        }

        var logCommandOutputPanelToggleSymbolNameForTesting: String? {
            logScrollView.commandOutputPanelToggleSymbolNameForTesting
        }

        var logCommandOutputPanelLeadingAlignmentDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelLeadingAlignmentDeltaForTesting
        }

        var logCommandOutputPanelChevronSizeDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelChevronSizeDeltaForTesting
        }

        var logCommandOutputPanelChevronVerticalAlignmentDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelChevronVerticalAlignmentDeltaForTesting
        }

        func logHitTestTargetsDocumentViewForFirstOccurrenceForTesting(_ text: String) -> Bool {
            logScrollView.hitTestTargetsDocumentViewForFirstLogOccurrenceForTesting(text)
        }

        func toggleFirstLogCommandOutputPanelForTesting() {
            logScrollView.toggleFirstCommandOutputPanelForTesting()
        }

        @discardableResult
        func clickFirstLogCommandOutputPanelHeaderForTesting() -> Bool {
            logScrollView.clickFirstCommandOutputPanelHeaderForTesting()
        }

        @discardableResult
        func clickLogCommandOutputPanelHeaderForTesting(blockID: ReviewMonitorLog.BlockID) -> Bool {
            logScrollView.clickCommandOutputPanelHeaderForTesting(blockID: blockID)
        }

        func completeLogWordGlowAnimationsForTesting() {
            logScrollView.completeWordGlowAnimationsForTesting()
        }

        func advanceLogWordGlowAnimationsAfterInitialDelayForTesting(_ delay: TimeInterval) {
            logScrollView.advanceWordGlowAnimationsAfterInitialDelayForTesting(delay)
        }

        func setLogReduceMotionForTesting(_ reduceMotion: Bool?) {
            logScrollView.setReduceMotionForTesting(reduceMotion)
        }

        var logUsesCustomTextKit2SurfaceForTesting: Bool {
            logScrollView.usesCustomTextKit2SurfaceForTesting
        }

        var logUsesTextViewForTesting: Bool {
            logScrollView.usesTextViewForTesting
        }

        var logUsesLogLayoutManagerForTesting: Bool {
            logScrollView.usesLogLayoutManagerForTesting
        }

        var logIsEditableForTesting: Bool {
            logScrollView.isEditableForTesting
        }

        var logIsSelectableForTesting: Bool {
            logScrollView.isSelectableForTesting
        }

        var logUsesFindBarForTesting: Bool {
            logScrollView.usesFindBarForTesting
        }

        var logIsIncrementalSearchingEnabledForTesting: Bool {
            logScrollView.isIncrementalSearchingEnabledForTesting
        }

        var logFindBarVisibleForTesting: Bool {
            logScrollView.isFindBarVisibleForTesting
        }

        var logTextFinderIdentifierForTesting: ObjectIdentifier {
            logScrollView.textFinderIdentifierForTesting
        }

        var logFindVisibleCharacterRangesForTesting: [NSRange] {
            logScrollView.findVisibleCharacterRangesForTesting
        }

        var logFindStringLengthForTesting: Int {
            logScrollView.findStringLengthForTesting
        }

        var logFindClientUsesSnapshotForTesting: Bool {
            logScrollView.findClientUsesSnapshotForTesting
        }

        var logFindClientSnapshotMapsToDocumentForTesting: Bool {
            logScrollView.findClientSnapshotMapsToDocumentForTesting
        }

        var logFindClientFirstSelectedRangeForTesting: NSRange {
            logScrollView.findClientFirstSelectedRangeForTesting
        }

        var logHasActiveFindQueryForTesting: Bool {
            logScrollView.hasActiveFindQueryForTesting
        }

        var logVisibleFindBarSearchStringForTesting: String? {
            logScrollView.visibleFindBarSearchStringForTesting
        }

        @discardableResult
        func setLogVisibleFindBarSearchStringForTesting(_ string: String) -> Bool {
            logScrollView.setVisibleFindBarSearchStringForTesting(string)
        }

        var logFindIndicatorInvalidationCountForTesting: Int {
            logScrollView.findIndicatorInvalidationCountForTesting
        }

        var logFindIncrementalMatchRangeCountForTesting: Int {
            logScrollView.findIncrementalMatchRangeCountForTesting
        }

        var logFindBarContainerContentViewIsTextContentViewForTesting: Bool {
            logScrollView.findBarContainerContentViewIsTextContentViewForTesting
        }

        var logFindIncrementalSearchUsesSystemHighlightingForTesting: Bool {
            logScrollView.findIncrementalSearchUsesSystemHighlightingForTesting
        }

        var logHitTestTargetsDocumentViewForTesting: Bool {
            logScrollView.hitTestTargetsDocumentViewForTesting
        }

        var logWritingToolsDisabledForTesting: Bool {
            logScrollView.writingToolsDisabledForTesting
        }

        var logOverlayScrollerHideRequestCountForTesting: Int {
            logScrollView.overlayScrollerHideRequestCountForTesting
        }

        var logRenderIsIdleForTesting: Bool {
            appliedLogRenderGeneration == logRenderGeneration
        }

        var logFrameForTesting: NSRect {
            logScrollView.frame
        }

        var viewFrameForTesting: NSRect {
            view.frame
        }

        var viewBoundsForTesting: NSRect {
            view.bounds
        }

        var safeAreaFrameForTesting: NSRect {
            view.safeAreaRect
        }

        var displayedViewFrameForTesting: NSRect {
            logScrollView.frame
        }

        var activeDisplayedViewConstraintCountForTesting: Int {
            displayedContentConstraints.filter(\.isActive).count
        }

        var renderSnapshotForTesting: RenderSnapshotForTesting {
            if isShowingEmptyStateForTesting {
                return .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: true
                )
            }
            return .init(
                title: displayedTitleForTesting,
                summary: displayedSummaryForTesting,
                log: displayedLogForTesting,
                isShowingEmptyState: false
            )
        }

        var renderedStateForTesting: RenderedStateForTesting {
            .init(
                snapshot: renderSnapshotForTesting,
                selection: displayedSelectionForTesting
            )
        }

        var expectedRenderSnapshotForTesting: RenderSnapshotForTesting {
            switch uiState.selection {
            case .job:
                .init(
                    title: nil,
                    summary: nil,
                    log: displayedLogForTesting,
                    isShowingEmptyState: false
                )
            case .workspaceSection:
                .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: false
                )
            case .workspace:
                .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: false
                )
            case .chat:
                .init(
                    title: nil,
                    summary: nil,
                    log: displayedLogForTesting,
                    isShowingEmptyState: false
                )
            case nil:
                .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: true
                )
            }
        }

        var expectedRenderedStateForTesting: RenderedStateForTesting {
            .init(
                snapshot: expectedRenderSnapshotForTesting,
                selection: expectedDisplayedSelectionForTesting
            )
        }

        private var displayedSelectionForTesting: DisplayedSelectionForTesting? {
            switch displayedSelection {
            case .job(let id):
                .job(id)
            case .workspaceSection(let id):
                .workspaceSection(id)
            case .workspace(let id):
                .workspace(id.rawValue)
            case .chat(let id):
                .chat(id.rawValue)
            case nil:
                nil
            }
        }

        private var expectedDisplayedSelectionForTesting: DisplayedSelectionForTesting? {
            switch uiState.selection {
            case .job(let job):
                .job(job.id)
            case .workspaceSection(let section):
                .workspaceSection(section.id)
            case .workspace(let workspace):
                .workspace(workspace.id.rawValue)
            case .chat(let chat):
                .chat(chat.id.rawValue)
            case nil:
                nil
            }
        }

        var workspaceFindingSnapshotForTesting: WorkspaceFindingSnapshotForTesting {
            .init(
                text: displayedWorkspaceFindingsForTesting,
                isShowingNoFindingsState: isShowingNoFindingsStateForTesting,
                isShowingFindingsList: isShowingWorkspaceFindingsListForTesting
            )
        }

        var workspaceFindingsContentWidthForTesting: CGFloat {
            view.layoutSubtreeIfNeeded()
            return workspaceFindingsView.contentWidthForTesting
        }

        var workspaceFindingsFrameForTesting: NSRect {
            workspaceFindingsView.frame
        }

        var workspaceFindingsTextContainerWidthForTesting: CGFloat {
            view.layoutSubtreeIfNeeded()
            return workspaceFindingsView.textContainerWidthForTesting
        }

        var workspaceFindingsScrollFrameForTesting: NSRect {
            workspaceFindingsView.scrollFrameForTesting
        }

        var workspaceFindingsDocumentFrameForTesting: NSRect {
            workspaceFindingsView.documentFrameForTesting
        }

        var workspaceFindingsNoFindingsFrameForTesting: NSRect {
            placeholderViewController.view.frame
        }

        var workspaceFindingsContentInsetsForTesting: NSEdgeInsets {
            workspaceFindingsView.contentInsetsForTesting
        }

        var workspaceFindingsVerticalScrollOffsetForTesting: CGFloat {
            workspaceFindingsView.verticalScrollOffsetForTesting
        }

        var workspaceFindingsMinimumVerticalScrollOffsetForTesting: CGFloat {
            workspaceFindingsView.minimumVerticalScrollOffsetForTesting
        }

        var workspaceFindingsMaximumVerticalScrollOffsetForTesting: CGFloat {
            workspaceFindingsView.maximumVerticalScrollOffsetForTesting
        }

        var workspaceFindingsAutomaticallyAdjustsContentInsetsForTesting: Bool {
            workspaceFindingsView.automaticallyAdjustsContentInsetsForTesting
        }

        var workspaceFindingsTextIsSelectableForTesting: Bool {
            workspaceFindingsView.isTextSelectableForTesting
        }

        var workspaceFindingsTextIsEditableForTesting: Bool {
            workspaceFindingsView.isTextEditableForTesting
        }

        var workspaceFindingsUsesFindBarForTesting: Bool {
            workspaceFindingsView.usesFindBarForTesting
        }

        var workspaceFindingsIsIncrementalSearchingEnabledForTesting: Bool {
            workspaceFindingsView.isIncrementalSearchingEnabledForTesting
        }

        var workspaceFindingsFindBarVisibleForTesting: Bool {
            workspaceFindingsView.isFindBarVisibleForTesting
        }

        var workspaceFindingsPriorityPrefixCountForTesting: Int {
            workspaceFindingsView.priorityPrefixCountForTesting
        }

        var workspaceFindingsTextAttachmentCountForTesting: Int {
            workspaceFindingsView.textAttachmentCountForTesting
        }

        var workspaceFindingsThreadBackgroundRangeCountForTesting: Int {
            workspaceFindingsView.threadBackgroundRangeCountForTesting
        }

        var workspaceFindingsAccessibilityValueForTesting: String? {
            workspaceFindingsView.accessibilityValueForTesting
        }

        var workspaceFindingsRenderedStorageStringForTesting: String {
            workspaceFindingsView.renderedStorageStringForTesting
        }

        func scrollLogToTopForTesting() {
            logScrollView.scrollToTopForTesting()
        }

        func scrollLogToOffsetForTesting(_ y: CGFloat) {
            logScrollView.scrollToOffsetForTesting(y)
        }

        var logVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.verticalScrollOffsetForTesting
        }

        var logViewportHeightForTesting: CGFloat {
            logScrollView.viewportHeightForTesting
        }

        var logMinimumVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.minimumVerticalScrollOffsetForTesting
        }

        var logMaximumVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.maximumVerticalScrollOffsetForTesting
        }

        var logTextContentFrameForTesting: NSRect {
            logScrollView.textContentFrameForTesting
        }

        var logDocumentViewFrameForTesting: NSRect {
            logScrollView.documentViewFrameForTesting
        }

        var logContentInsetsForTesting: NSEdgeInsets {
            logScrollView.contentInsetsForTesting
        }

        var logAutomaticallyAdjustsContentInsetsForTesting: Bool {
            logScrollView.automaticallyAdjustsContentInsetsForTesting
        }

        var logTextContainerSizeForTesting: NSSize {
            logScrollView.textContainerSizeForTesting
        }

        var logTextContainerInsetForTesting: NSSize {
            logScrollView.textContainerInsetForTesting
        }

        var logVisibleFragmentViewCountForTesting: Int {
            logScrollView.visibleFragmentViewCountForTesting
        }

        var logVisibleFragmentViewCountWithoutForcingLayoutForTesting: Int {
            logScrollView.visibleFragmentViewCountWithoutForcingLayoutForTesting
        }

        var logVisibleFragmentBoundsForTesting: NSRect {
            logScrollView.visibleFragmentBoundsForTesting
        }

        var logVisibleFragmentBoundsWithoutForcingLayoutForTesting: NSRect {
            logScrollView.visibleFragmentBoundsWithoutForcingLayoutForTesting
        }

        var logStaleFragmentViewCountForTesting: Int {
            logScrollView.staleFragmentViewCountForTesting
        }

        var logProgrammaticScrollCountForTesting: Int {
            logScrollView.programmaticScrollCountForTesting
        }

        var logAccessibilityValueForTesting: String? {
            logScrollView.accessibilityValueForTesting
        }

        var logSelectedTextForTesting: String? {
            logScrollView.selectedTextForTesting
        }

        var logSelectedRangeForTesting: NSRange {
            logScrollView.selectedRangeForTesting
        }

        var logFindStringForTesting: String {
            logScrollView.findStringForTesting
        }

        func selectAllLogForTesting() {
            logScrollView.selectAllForTesting()
        }

        func setSelectedLogRangeForTesting(_ range: NSRange) {
            logScrollView.setSelectedLogRangeForTesting(range)
        }

        var logDocumentViewExportsUserInterfaceValidationForTesting: Bool {
            logScrollView.documentViewExportsUserInterfaceValidationForTesting
        }

        func validateLogDocumentUserInterfaceItemForTesting(_ item: NSValidatedUserInterfaceItem) -> Bool {
            logScrollView.validateDocumentUserInterfaceItemForTesting(item)
        }

        func clearLogFinderSelectedRangesForTesting() {
            logScrollView.clearFinderSelectedRangesForTesting()
        }

        func setLogFinderSelectedRangeForTesting(_ range: NSRange) {
            logScrollView.setFinderSelectedRangeForTesting(range)
        }

        func simulateLogFinderEmptySelectedRangesForTesting() {
            logScrollView.simulateFinderEmptySelectedRangesForTesting()
        }

        func performLogKeyboardCommandForTesting(_ selector: Selector) {
            logScrollView.performKeyboardCommandForTesting(selector)
        }

        @discardableResult
        func renderLogForTesting(text: String, allowIncrementalUpdate: Bool) -> Bool {
            logScrollView.renderForTesting(text: text, allowIncrementalUpdate: allowIncrementalUpdate)
        }

        @discardableResult
        func renderTimelineDocumentForTesting(
            _ timelineDocument: ReviewTimelineDocument,
            target: DisplayedSelectionForTesting? = nil,
            restoring restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget? = nil,
            allowIncrementalUpdate: Bool
        ) -> Bool {
            let resolvedTarget: LogRenderTarget
            switch target ?? displayedSelectionForTesting {
            case .job(let id):
                resolvedTarget = .job(id)
            case .chat(let id):
                resolvedTarget = .chat(CodexThreadID(rawValue: id))
            case .workspaceSection, .workspace, nil:
                return false
            }
            let resolvedRestorationTarget =
                restorationTarget
                ?? {
                    guard hasAppliedBoundLog == false else {
                        return logScrollView.currentScrollRestorationTarget
                    }
                    switch resolvedTarget {
                    case .job(let id):
                        return logScrollTargetsByJobID[id] ?? .bottom
                    case .chat:
                        return .bottom
                    }
                }()
            let renderedDocument = logDocumentForTesting(from: timelineDocument)
            return renderBoundLog(
                sourceDocument: renderedDocument,
                target: resolvedTarget,
                restorationTarget: resolvedRestorationTarget,
                allowIncrementalUpdate: allowIncrementalUpdate
            )
        }

        private func logDocumentForTesting(
            from timelineDocument: ReviewTimelineDocument
        ) -> ReviewMonitorLog.Document {
            previewTimelineLogProjection.render(timelineDocument: timelineDocument)
        }

        func copyLogSelectionForTesting() {
            logScrollView.copySelectionForTesting()
        }

        func beginLogLiveResizeForTesting() {
            logScrollView.beginLiveResizeForTesting()
        }

        func endLogLiveResizeForTesting() {
            logScrollView.endLiveResizeForTesting()
        }

        func scrollLogToBottomForTesting() {
            logScrollView.scrollToBottomForTesting()
        }

        var isLogPinnedToBottomForTesting: Bool {
            logScrollView.isPinnedToBottomForTesting
        }

        func setLogScrollerStyleForTesting(_ style: NSScroller.Style) {
            logScrollView.setScrollerStyleForTesting(style)
        }

        func setLogOverlayScrollersShownForTesting(_ isShown: Bool?) {
            logScrollView.setOverlayScrollersShownForTesting(isShown)
        }

        func setLogOverlayScrollerBridgeModeForTesting(
            _ mode: ReviewMonitorLogScrollView.OverlayScrollerBridgeModeForTesting
        ) {
            logScrollView.setOverlayScrollerBridgeModeForTesting(mode)
        }
    }
#endif
