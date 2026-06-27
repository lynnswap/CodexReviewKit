import AppKit
import Combine
import CodexKit
import ObservationBridge
import CodexReviewKit

typealias ReviewMonitorContentTransitionAnimator = @MainActor (
    NSView,
    NSView,
    @escaping @MainActor () -> Void
) -> Void

@MainActor
final class ReviewMonitorRootViewController: NSViewController {
    private let uiState: ReviewMonitorUIState
    private let store: CodexReviewStore
    private let codexModelSource: ReviewMonitorCodexModelSource?
    private let previewChatLogSource: ReviewMonitorPreviewChatLogSource?
    private let contentTransitionAnimator: ReviewMonitorContentTransitionAnimator
    private let showSettings: (@MainActor () -> Void)?
    private var observation: PortableObservationTracking.Token?
    private var windowCancellable: AnyCancellable?
    private var presentedContentKind: ReviewMonitorContentKind?

    private lazy var splitViewController = ReviewMonitorSplitViewController(
        store: store,
        uiState: uiState,
        codexModelSource: codexModelSource,
        previewChatLogSource: previewChatLogSource,
        showSettings: showSettings
    )

    private lazy var signInViewController = ReviewMonitorSignInViewController(store: store)

    convenience init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        modelContext: CodexModelContext,
        previewChatLogSource: ReviewMonitorPreviewChatLogSource? = nil,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator = ReviewMonitorRootViewController.defaultContentTransitionAnimator,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        self.init(
            store: store,
            uiState: uiState,
            codexModelSource: ReviewMonitorCodexModelSource(modelContext: modelContext),
            previewChatLogSource: previewChatLogSource,
            contentTransitionAnimator: contentTransitionAnimator,
            showSettings: showSettings
        )
    }

    init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        codexModelSource: ReviewMonitorCodexModelSource? = nil,
        previewChatLogSource: ReviewMonitorPreviewChatLogSource? = nil,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator = ReviewMonitorRootViewController.defaultContentTransitionAnimator,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.uiState = uiState
        self.codexModelSource = codexModelSource
        self.previewChatLogSource = previewChatLogSource
        self.contentTransitionAnimator = contentTransitionAnimator
        self.showSettings = showSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observation?.cancel()
    }

    override func loadView() {
        let backgroundView = NSVisualEffectView()
        backgroundView.material = .underWindowBackground
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        view = backgroundView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindWindowState()
        bindWindowAttachment()
    }

    private func bindWindowState() {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self, uiState] event in
            let kind = uiState.contentKind
            self?.setContentViewController(kind, animated: event.kind != .initial)
        }
    }

    func applyInitialWindowPresentationIfPossible() {
        guard let window = view.window else {
            return
        }

        applyWindowPresentation(to: window)
    }

    private func bindWindowAttachment() {
        windowCancellable = view.publisher(for: \.window, options: [.initial, .new])
            .sink { [weak self] window in
                MainActor.assumeIsolated {
                    guard let self, let window else {
                        return
                    }
                    self.applyWindowPresentation(to: window)
                }
            }
    }

    private func applyWindowPresentation(to window: NSWindow) {
        switch presentedContentKind ?? uiState.contentKind {
        case .contentView:
            splitViewController.attach(to: window)
        case .signInView:
            signInViewController.applyWindowPresentation(to: window)
        }
    }

    private func setContentViewController(
        _ kind: ReviewMonitorContentKind,
        animated: Bool
    ) {
        if presentedContentKind == kind {
            return
        }

        let incomingContentViewController: NSViewController
        let outgoingContentViewController: NSViewController?
        switch kind {
        case .contentView:
            incomingContentViewController = splitViewController
            outgoingContentViewController = presentedContentKind == nil ? nil : signInViewController
        case .signInView:
            incomingContentViewController = signInViewController
            outgoingContentViewController = presentedContentKind == nil ? nil : splitViewController
        }

        if incomingContentViewController.parent == nil {
            addChild(incomingContentViewController)
        }

        if animated,
           let outgoingContentViewController,
           outgoingContentViewController.view.superview === view {
            let incomingContentView = incomingContentViewController.view
            incomingContentView.alphaValue = 0
            installEmbeddedContentView(
                incomingContentView,
                positioned: .above,
                relativeTo: outgoingContentViewController.view
            )
            presentedContentKind = kind

            contentTransitionAnimator(
                outgoingContentViewController.view,
                incomingContentView
            ) { [weak self, weak outgoingContentViewController] in
                guard let self else {
                    return
                }
                incomingContentView.alphaValue = 1
                outgoingContentViewController?.view.alphaValue = 1
                guard self.presentedContentKind == kind else {
                    return
                }
                if let outgoingContentViewController {
                    self.removeEmbeddedContent(for: outgoingContentViewController)
                }
            }
        } else {
            if let outgoingContentViewController {
                removeEmbeddedContent(for: outgoingContentViewController)
            }
            installEmbeddedContentView(incomingContentViewController.view)
            presentedContentKind = kind
        }

        switch kind {
        case .contentView:
            if let window = view.window {
                splitViewController.attach(to: window)
            }
        case .signInView:
            signInViewController.applyWindowPresentationIfPossible()
        }
    }

    private func installEmbeddedContentView(
        _ contentView: NSView,
        positioned: NSWindow.OrderingMode? = nil,
        relativeTo relativeView: NSView? = nil
    ) {
        let existingConstraints = view.constraints.filter { constraint in
            constraint.firstItem as AnyObject? === contentView
                || constraint.secondItem as AnyObject? === contentView
        }
        NSLayoutConstraint.deactivate(existingConstraints)
        contentView.removeFromSuperview()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        if let positioned {
            view.addSubview(
                contentView,
                positioned: positioned,
                relativeTo: relativeView
            )
        } else {
            view.addSubview(contentView)
        }
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func removeEmbeddedContent(for viewController: NSViewController) {
        viewController.view.removeFromSuperview()
        if viewController.parent != nil {
            viewController.removeFromParent()
        }
    }

    static func defaultContentTransitionAnimator(
        outgoingView: NSView,
        incomingView: NSView,
        completion: @escaping @MainActor () -> Void
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            outgoingView.animator().alphaValue = 0
            incomingView.animator().alphaValue = 1
        } completionHandler: {
            Task { @MainActor in
                completion()
            }
        }
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorRootViewController {
    func prepareForSwiftUIPreviewRendering() {
        loadViewIfNeeded()
        splitViewController.prepareForSwiftUIPreviewRendering()
        view.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func appendPreviewChatLogStreamTickForTesting(after tick: Int = 0) -> Int? {
        previewChatLogSource?.appendPreviewStreamTick(after: tick)
    }

    var splitViewControllerForTesting: ReviewMonitorSplitViewController {
        splitViewController
    }

    var contentKindForTesting: ReviewMonitorContentKind {
        isShowingSplitViewForTesting ? .contentView : .signInView
    }

    var isSplitViewEmbeddedForTesting: Bool {
        children.first === splitViewController &&
        splitViewController.parent === self &&
        splitViewController.view.superview === view
    }

    var isSignInViewEmbeddedForTesting: Bool {
        children.first === signInViewController &&
        signInViewController.parent === self &&
        signInViewController.view.superview === view
    }

    var isShowingSplitViewForTesting: Bool {
        children.first === splitViewController
    }

    var embeddedContentSubviewCountForTesting: Int {
        view.subviews.count
    }
}

@MainActor
func makeReviewMonitorPreviewContentViewController() -> NSViewController {
    makeReviewMonitorPreviewContentViewControllerForPreview()
}

@MainActor
func makeReviewMonitorPreviewContentViewControllerForPreview(
    authPhase: CodexReviewAuthModel.Phase = .signedOut,
    account: CodexReviewAccount? = nil,
    serverState: CodexReviewServerState = .running,
    previewStore: CodexReviewStore? = nil
) -> ReviewMonitorRootViewController {
    let store: CodexReviewStore
    let ownsPreviewStore = previewStore == nil
    switch serverState {
    case .running:
        store = previewStore ?? ReviewMonitorPreviewContent.makeStore(streamInterval: nil)
    case .failed, .starting, .stopped:
        store = CodexReviewStore.makePreviewStore()
        store.serverState = serverState
        store.serverURL = nil
    }
    let previewAccounts = ReviewMonitorPreviewContent.makePreviewAccounts()
    let resolvedAccount = account ?? previewAccounts.first
    store.auth.updatePhase(authPhase)
    store.auth.applyPersistedAccountStates(previewAccounts.map(savedAccountPayload(from:)))
    store.auth.selectPersistedAccount(resolvedAccount?.id)
    let uiState = ReviewMonitorUIState(auth: store.auth)
    let previewChatLogSource: ReviewMonitorPreviewChatLogSource? =
        if case .running = serverState {
            ReviewMonitorPreviewChatLogSource(
                fixtures: ReviewMonitorPreviewContent.makeChatLogFixtures(from: store.orderedJobs)
            )
        } else {
            nil
        }
    if let initialChat = previewChatLogSource?.initialChat {
        uiState.selection = .chat(initialChat)
    }
    if ownsPreviewStore, let previewChatLogSource {
        store.previewSupportRetainer = ReviewMonitorPreviewChatLogStreamer(
            source: previewChatLogSource,
            interval: .milliseconds(40)
        )
    }
    return ReviewMonitorRootViewController(
        store: store,
        uiState: uiState,
        previewChatLogSource: previewChatLogSource
    )
}
#endif
