import AppKit
import Combine
import ObservationBridge
import CodexReview

typealias ReviewMonitorContentTransitionAnimator = @MainActor (
    NSView,
    NSView,
    @escaping @MainActor () -> Void
) -> Void

@MainActor
final class ReviewMonitorRootViewController: NSViewController {
    private let uiState: ReviewMonitorUIState
    private let store: CodexReviewStore
    private let contentTransitionAnimator: ReviewMonitorContentTransitionAnimator
    private let observationScope = ObservationScope()
    private var windowCancellable: AnyCancellable?

    private lazy var splitViewController = ReviewMonitorSplitViewController(
        store: store,
        uiState: uiState
    )

    private lazy var signInViewController = ReviewMonitorSignInViewController(store: store)

    init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator = ReviewMonitorRootViewController.defaultContentTransitionAnimator
    ) {
        self.store = store
        self.uiState = uiState
        self.contentTransitionAnimator = contentTransitionAnimator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
        setContentViewController(uiState.contentKind, animated: false)
        bindWindowState()
        bindWindowAttachment()
    }

    private func bindWindowState() {
        observationScope.update {
            uiState.observe(\.contentKind) { [weak self] kind in
                self?.setContentViewController(kind, animated: true)
            }
            .store(in: observationScope)
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
        switch uiState.presentedContentKind ?? uiState.contentKind {
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
        if uiState.presentedContentKind == kind {
            return
        }

        let incomingContentViewController: NSViewController
        let outgoingContentViewController: NSViewController?
        switch kind {
        case .contentView:
            incomingContentViewController = splitViewController
            outgoingContentViewController = uiState.presentedContentKind == nil ? nil : signInViewController
        case .signInView:
            incomingContentViewController = signInViewController
            outgoingContentViewController = uiState.presentedContentKind == nil ? nil : splitViewController
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
            uiState.presentedContentKind = kind

            contentTransitionAnimator(
                outgoingContentViewController.view,
                incomingContentView
            ) { [weak self, weak outgoingContentViewController] in
                guard let self else {
                    return
                }
                incomingContentView.alphaValue = 1
                outgoingContentViewController?.view.alphaValue = 1
                guard self.uiState.presentedContentKind == kind else {
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
            uiState.presentedContentKind = kind
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
    account: CodexAccount? = nil,
    serverState: CodexReviewServerState = .running
) -> ReviewMonitorRootViewController {
    let store: CodexReviewStore
    switch serverState {
    case .running:
        store = ReviewMonitorPreviewContent.makeStore()
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
    if case .running = serverState,
       let previewJob = store.orderedJobs
           .first(where: { $0.core.lifecycle.status == .running })
           ?? store.orderedJobs.first
    {
        uiState.selection = .job(previewJob)
    }
    return ReviewMonitorRootViewController(store: store, uiState: uiState)
}
#endif
