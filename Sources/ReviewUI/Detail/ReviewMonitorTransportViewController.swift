import AppKit
import ObservationBridge
import CodexReview

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private enum DisplayedSelection: Equatable {
        case job(String)
        case workspace(String)
    }

    private let uiState: ReviewMonitorUIState
    private let store: CodexReviewStore
    private let logScrollView = ReviewMonitorLogScrollView()
    private var logRenderer = ReviewMonitorLogRenderer()
    private let workspaceFindingsView = ReviewMonitorWorkspaceFindingsView()
    private let placeholderViewController = PlaceholderViewController()
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private let uiStateObservationScope = ObservationScope()
    private let selectedJobObservationScope = ObservationScope()
    private let selectedWorkspaceObservationScope = ObservationScope()
    private var selectionDelivery: ObservationDelivery?
    private var selectedJobDelivery: ObservationDelivery?
    private var selectedWorkspaceFindingsDelivery: ObservationDelivery?
    private var boundJob: CodexReviewJob?
    private var boundWorkspace: CodexReviewWorkspace?
    private var displayedSelection: DisplayedSelection?
    private var logScrollTargetsByJobID: [String: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
    private var logRenderTask: Task<Void, Never>?
    private var logRenderGeneration: UInt64 = 0
    private var appliedLogRenderGeneration: UInt64 = 0
    private var appliedLogEntryCount = 0
    private var hasAppliedBoundJobLog = false

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
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
        uiStateObservationScope.cancelAll()
        selectionDelivery = uiStateObservationScope.observe(uiState) { [weak self] event, uiState in
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
            return boundJob !== selectedJob || displayedSelection != .job(selectedJob.id)
        case .workspace(let selectedWorkspace):
            return boundWorkspace !== selectedWorkspace || displayedSelection != .workspace(selectedWorkspace.cwd)
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
            displayedSelection = .job(selectedJob.id)

        case .workspace(let selectedWorkspace):
            clearDisplayedJob()
            displayWorkspace(selectedWorkspace)
            logScrollView.isHidden = true
            displayedSelection = .workspace(selectedWorkspace.cwd)

        case nil:
            clearDisplayedJob()
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
        selectedJobObservationScope.cancelAll()
        selectedJobDelivery = nil
        resetLogRenderer()
        boundJob = selectedJob

        selectedJobDelivery = selectedJobObservationScope.observe(selectedJob, tracking: { selectedJob in
            _ = selectedJob.logRevision
        }) { [weak self] event, selectedJob in
            guard let self,
                  self.boundJob === selectedJob
            else {
                return
            }
            self.renderBoundJobLog(
                selectedJob,
                restorationTarget: event.kind == .initial
                    ? self.restorationTarget(selectedJob)
                    : self.logScrollView.currentScrollRestorationTarget,
                allowIncrementalUpdate: event.kind != .initial
            )
        }
    }

    private func clearDisplayedJob() {
        cacheBoundJobScrollTarget()
        selectedJobObservationScope.cancelAll()
        selectedJobDelivery = nil
        boundJob = nil
        resetLogRenderer()
        logScrollView.resetFindStateForContentReuse()
        logScrollView.clear()
    }

    private func displayWorkspace(_ workspace: CodexReviewWorkspace) {
        if boundWorkspace !== workspace {
            selectedWorkspaceObservationScope.cancelAll()
            selectedWorkspaceFindingsDelivery = nil
            boundWorkspace = workspace
            bindWorkspaceObservation(workspace)
        }
    }

    private func clearDisplayedWorkspace() {
        selectedWorkspaceObservationScope.cancelAll()
        selectedWorkspaceFindingsDelivery = nil
        boundWorkspace = nil
        workspaceFindingsView.clear()
        workspaceFindingsView.isHidden = true
    }

    private func bindWorkspaceObservation(_ workspace: CodexReviewWorkspace) {
        selectedWorkspaceFindingsDelivery = selectedWorkspaceObservationScope.observe(store) { [weak self, weak workspace] _, _ in
            guard let self,
                  let workspace,
                  self.boundWorkspace === workspace
            else {
                return
            }
            let entries = self.workspaceFindingEntries(for: workspace)
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
        for workspace: CodexReviewWorkspace
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

    private func locationText(
        for location: ParsedReviewFindingLocation?,
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
        return fileComponents
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
    private func renderSelectedJobLog(
        entries: [ReviewLogEntry],
        targetEntryCount: Int,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        guard let boundJob else {
            return false
        }

        logRenderGeneration &+= 1
        let generation = logRenderGeneration
        let renderer = logRenderer
        let jobID = boundJob.id
        logRenderTask?.cancel()
        logRenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let document = await renderer.render(entries: entries)
            await MainActor.run { [weak self] in
                guard Task.isCancelled == false,
                      let self,
                      self.logRenderGeneration == generation,
                      self.boundJob?.id == jobID
                else {
                    return
                }
                _ = self.logScrollView.render(
                    document: document,
                    restoring: restorationTarget,
                    allowIncrementalUpdate: allowIncrementalUpdate
                )
                self.appliedLogEntryCount = targetEntryCount
                self.appliedLogRenderGeneration = generation
                self.hasAppliedBoundJobLog = true
            }
        }
        return true
    }

    @discardableResult
    private func renderSelectedJobLogAppend(
        entries: [ReviewLogEntry],
        sourceRange: Range<Int>,
        targetEntryCount: Int
    ) -> Bool {
        guard let boundJob else {
            return false
        }

        logRenderGeneration &+= 1
        let generation = logRenderGeneration
        let renderer = logRenderer
        let jobID = boundJob.id
        logRenderTask?.cancel()
        logRenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let resolved: (document: ReviewMonitorLogDocument, entryCount: Int)
            if let document = await renderer.append(entries: entries, sourceRange: sourceRange) {
                resolved = (document, targetEntryCount)
            } else {
                guard let fallback = await MainActor.run(body: { [weak self] () -> (entries: [ReviewLogEntry], entryCount: Int)? in
                    guard Task.isCancelled == false,
                          let self,
                          self.logRenderGeneration == generation,
                          self.boundJob?.id == jobID,
                          let entries = self.boundJob?.logEntries
                    else {
                        return nil
                    }
                    return (entries, entries.count)
                }) else {
                    return
                }
                let document = await renderer.render(entries: fallback.entries)
                resolved = (document, fallback.entryCount)
            }
            await MainActor.run { [weak self] in
                guard Task.isCancelled == false,
                      let self,
                      self.logRenderGeneration == generation,
                      self.boundJob?.id == jobID
                else {
                    return
                }
                _ = self.logScrollView.render(
                    document: resolved.document,
                    restoring: self.logScrollView.currentScrollRestorationTarget,
                    allowIncrementalUpdate: true
                )
                self.appliedLogEntryCount = resolved.entryCount
                self.appliedLogRenderGeneration = generation
                self.hasAppliedBoundJobLog = true
            }
        }
        return true
    }

    @discardableResult
    private func renderBoundJobLog(
        _ job: CodexReviewJob,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        guard boundJob != nil else {
            return false
        }
        let entries = job.logEntries
        let targetEntryCount = entries.count
        if allowIncrementalUpdate,
           hasAppliedBoundJobLog,
           job.lastLogMutation == .append,
           appliedLogEntryCount <= targetEntryCount {
            let appendedEntries = Array(entries.dropFirst(appliedLogEntryCount))
            if appendedEntries.isEmpty {
                appliedLogEntryCount = targetEntryCount
                return false
            }
            return renderSelectedJobLogAppend(
                entries: appendedEntries,
                sourceRange: appliedLogEntryCount..<targetEntryCount,
                targetEntryCount: targetEntryCount
            )
        }
        return renderSelectedJobLog(
            entries: entries,
            targetEntryCount: targetEntryCount,
            restorationTarget: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
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
        appliedLogEntryCount = 0
        hasAppliedBoundJobLog = false
        logRenderer = ReviewMonitorLogRenderer()
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
        case .workspace:
            return workspaceFindingsView.performDisplayedTextFinderAction(sender)
        case nil:
            return false
        }
    }

    func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch displayedSelection {
        case .job:
            return logScrollView.validateDisplayedTextFinderAction(item)
        case .workspace:
            return workspaceFindingsView.validateDisplayedTextFinderAction(item)
        case nil:
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
        case workspace(String)
    }

    struct RenderedStateForTesting: Sendable, Equatable {
        let snapshot: RenderSnapshotForTesting
        let selection: DisplayedSelectionForTesting?
    }

    var selectionDeliveryForTesting: ObservationDelivery? {
        selectionDelivery
    }

    var selectedJobDeliveryForTesting: ObservationDelivery? {
        selectedJobDelivery
    }

    var selectedWorkspaceFindingsDeliveryForTesting: ObservationDelivery? {
        selectedWorkspaceFindingsDelivery
    }

    var deliveryForExpectedRenderedStateForTesting: ObservationDelivery? {
        let expectedSelection = expectedRenderedStateForTesting.selection
        if displayedSelectionForTesting != expectedSelection {
            return selectionDelivery
        }
        switch expectedSelection {
        case .job:
            return selectedJobDelivery ?? selectionDelivery
        case .workspace:
            return selectedWorkspaceFindingsDelivery ?? selectionDelivery
        case nil:
            return selectionDelivery
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
        placeholderViewController.view.isHidden == false &&
            placeholderViewController.content == .noSelection
    }

    var emptyStateFrameForTesting: NSRect {
        placeholderViewController.view.frame
    }

    var isShowingNoFindingsStateForTesting: Bool {
        placeholderViewController.view.isHidden == false &&
            placeholderViewController.content == .noFindings
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

    var logCommandOutputPanelCommandLineTextForTesting: String? {
        logScrollView.commandOutputPanelCommandLineTextForTesting
    }

    var logCommandOutputPanelOutputScrollTextForTesting: String? {
        logScrollView.commandOutputPanelOutputScrollTextForTesting
    }

    var logCommandOutputPanelOutputScrollIsScrollableForTesting: Bool {
        logScrollView.commandOutputPanelOutputScrollIsScrollableForTesting
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

    func completeLogWordGlowAnimationsForTesting() {
        logScrollView.completeWordGlowAnimationsForTesting()
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

    var logUsesLegacyLayoutManagerForTesting: Bool {
        logScrollView.usesLegacyLayoutManagerForTesting
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
        case .job(let job):
            .init(
                title: nil,
                summary: nil,
                log: {
                    var projection = ReviewMonitorLogProjection()
                    let document = projection.render(entries: job.logEntries)
                    return logScrollView.displayTextForTesting(sourceDocument: document)
                }(),
                isShowingEmptyState: false
            )
        case .workspace:
            .init(
                title: nil,
                summary: nil,
                log: "",
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
        case .workspace(let cwd):
            .workspace(cwd)
        case nil:
            nil
        }
    }

    private var expectedDisplayedSelectionForTesting: DisplayedSelectionForTesting? {
        switch uiState.selection {
        case .job(let job):
            .job(job.id)
        case .workspace(let workspace):
            .workspace(workspace.cwd)
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

    var logVisibleFragmentBoundsForTesting: NSRect {
        logScrollView.visibleFragmentBoundsForTesting
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

    var logContextMenuForTesting: NSMenu? {
        logScrollView.contextMenuForTesting()
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
