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
    private let workspaceFindingsView = ReviewMonitorWorkspaceFindingsView()
    private let placeholderViewController = PlaceholderViewController()
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private let uiStateObservationScope = ObservationScope()
    private let selectedJobObservationScope = ObservationScope()
    private let selectedWorkspaceObservationScope = ObservationScope()
    private var boundJob: CodexReviewJob?
    private var boundWorkspace: CodexReviewWorkspace?
    private var displayedSelection: DisplayedSelection?
    private var logScrollTargetsByJobID: [String: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
#if DEBUG
    private var renderCountForTestingStorage = 0
    private var renderWaitersForTesting: [Int: [CheckedContinuation<Void, Never>]] = [:]
#endif

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
        uiStateObservationScope.observe(uiState) { [weak self] event, uiState in
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
        let previousSelection = displayedSelection
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

        if previousSelection != displayedSelection {
            noteRenderForTesting()
        }
    }

    private func displayJob(_ selectedJob: CodexReviewJob) {
        cacheBoundJobScrollTarget()
        selectedJobObservationScope.cancelAll()
        boundJob = selectedJob

        selectedJobObservationScope.observe(selectedJob) { [weak self] event, selectedJob in
            let text = selectedJob.reviewMonitorLogText
            guard let self,
                  self.boundJob === selectedJob
            else {
                return
            }
            let logChanged = self.renderBoundJobLog(
                text,
                restorationTarget: event.kind == .initial
                    ? self.restorationTarget(selectedJob)
                    : self.logScrollView.currentScrollRestorationTarget,
                allowIncrementalUpdate: event.kind != .initial
            )
            if logChanged {
                self.noteRenderForTesting()
            }
        }
    }

    private func clearDisplayedJob() {
        cacheBoundJobScrollTarget()
        selectedJobObservationScope.cancelAll()
        boundJob = nil
        if logScrollView.clear() {
            noteRenderForTesting()
        }
    }

    private func displayWorkspace(_ workspace: CodexReviewWorkspace) {
        if boundWorkspace !== workspace {
            selectedWorkspaceObservationScope.cancelAll()
            boundWorkspace = workspace
            bindWorkspaceObservation(workspace)
        }
    }

    private func clearDisplayedWorkspace() {
        selectedWorkspaceObservationScope.cancelAll()
        boundWorkspace = nil
        if workspaceFindingsView.clear() {
            noteRenderForTesting()
        }
        workspaceFindingsView.isHidden = true
    }

    private func bindWorkspaceObservation(_ workspace: CodexReviewWorkspace) {
        selectedWorkspaceObservationScope.observe(store) { [weak self, weak workspace] _, _ in
            guard let self,
                  let workspace,
                  self.boundWorkspace === workspace
            else {
                return
            }
            let entries = self.workspaceFindingEntries(for: workspace)
            if self.renderWorkspaceFindings(entries: entries) {
                self.noteRenderForTesting()
            }
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
        _ text: String,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        logScrollView.render(
            text: text,
            restoring: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
    }

    @discardableResult
    private func renderBoundJobLog(
        _ text: String,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        guard boundJob != nil else {
            return false
        }
        return renderSelectedJobLog(
            text,
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

    private func noteRenderForTesting() {
#if DEBUG
        renderCountForTestingStorage += 1
        let readyCounts = renderWaitersForTesting.keys.filter { $0 <= renderCountForTestingStorage }
        for count in readyCounts {
            let continuations = renderWaitersForTesting.removeValue(forKey: count) ?? []
            for continuation in continuations {
                continuation.resume()
            }
        }
#endif
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorTransportViewController {
    struct RenderSnapshotForTesting: Equatable {
        let title: String?
        let summary: String?
        let log: String
        let isShowingEmptyState: Bool
    }

    struct WorkspaceFindingSnapshotForTesting: Equatable {
        let text: String
        let isShowingNoFindingsState: Bool
        let isShowingFindingsList: Bool
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

    var renderCountForTesting: Int {
        renderCountForTestingStorage
    }

    var logAppendCountForTesting: Int {
        logScrollView.appendCount
    }

    var logReloadCountForTesting: Int {
        logScrollView.reloadCount
    }

    var logAutoFollowCountForTesting: Int {
        logScrollView.autoFollowCount
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

    var logFindVisibleCharacterRangesForTesting: [NSRange] {
        logScrollView.findVisibleCharacterRangesForTesting
    }

    var logFindStringLengthForTesting: Int {
        logScrollView.findStringLengthForTesting
    }

    var logFindClientStringWillChangeCountForTesting: Int {
        logScrollView.findClientStringWillChangeCountForTesting
    }

    var logFindIndicatorInvalidationCountForTesting: Int {
        logScrollView.findIndicatorInvalidationCountForTesting
    }

    var logFindBarContainerContentViewIsTextContentViewForTesting: Bool {
        logScrollView.findBarContainerContentViewIsTextContentViewForTesting
    }

    var logFindIncrementalSearchUsesSystemHighlightingForTesting: Bool {
        logScrollView.findIncrementalSearchUsesSystemHighlightingForTesting
    }

    var logFindFeedbackDimmingEnabledForTesting: Bool {
        logScrollView.findFeedbackDimmingEnabledForTesting
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

    func waitForRenderCountForTesting(_ targetCount: Int) async {
        if renderCountForTestingStorage >= targetCount {
            return
        }
        await withCheckedContinuation { continuation in
            if renderCountForTestingStorage >= targetCount {
                continuation.resume()
                return
            }
            renderWaitersForTesting[targetCount, default: []].append(continuation)
        }
    }

    func flushMainQueueForTesting() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
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

    func selectAllLogForTesting() {
        logScrollView.selectAllForTesting()
    }

    func setSelectedLogRangeForTesting(_ range: NSRange) {
        logScrollView.setSelectedLogRangeForTesting(range)
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
