import AppKit
import CodexReview

@MainActor
func configureReviewMonitorWindowBase(_ window: NSWindow) {
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    window.isMovableByWindowBackground = false
    window.styleMask.insert(.fullSizeContentView)
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = false
    window.titlebarSeparatorStyle = .automatic
}

@Observable
public final class ReviewMonitorWindowController: NSWindowController {
    private static let defaultContentSize = NSSize(width: 600, height: 400)
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("ReviewMonitor.MainWindow")
    private let rootViewController: ReviewMonitorRootViewController

    public convenience init(store: CodexReviewStore) {
        self.init(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator
        )
    }

    convenience init(
        store: CodexReviewStore,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator
    ) {
        self.init(
            store: store,
            contentTransitionAnimator: contentTransitionAnimator,
            frameAutosaveName: Self.frameAutosaveName
        )
    }

    init(
        store: CodexReviewStore,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator,
        frameAutosaveName: NSWindow.FrameAutosaveName
    ) {
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let rootViewController = ReviewMonitorRootViewController(
            store: store,
            uiState: uiState,
            contentTransitionAnimator: contentTransitionAnimator
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        configureReviewMonitorWindowBase(window)
        window.contentViewController = rootViewController
        window.setContentSize(Self.defaultContentSize)

        self.rootViewController = rootViewController
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(frameAutosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
