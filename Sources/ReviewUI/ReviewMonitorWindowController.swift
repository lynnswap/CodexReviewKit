import AppKit
import CodexReviewKit

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

public final class ReviewMonitorWindowController: NSWindowController {
    private static let defaultContentSize = NSSize(width: 600, height: 400)
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("ReviewMonitor.MainWindow")
    private let rootViewController: ReviewMonitorRootViewController

    public convenience init(store: CodexReviewStore) {
        self.init(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            showSettings: nil
        )
    }

    @_spi(PreviewSupport)
    public convenience init(
        store: CodexReviewStore,
        showSettings: @escaping @MainActor () -> Void
    ) {
        self.init(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            showSettings: showSettings
        )
    }

    convenience init(
        store: CodexReviewStore,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator,
        sidebarJobFilterDefaults: UserDefaults? = .standard,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        self.init(
            store: store,
            contentTransitionAnimator: contentTransitionAnimator,
            frameAutosaveName: Self.frameAutosaveName,
            sidebarJobFilterDefaults: sidebarJobFilterDefaults,
            showSettings: showSettings
        )
    }

    init(
        store: CodexReviewStore,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator,
        frameAutosaveName: NSWindow.FrameAutosaveName,
        sidebarJobFilterDefaults: UserDefaults? = .standard,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        let uiState = Self.makeUIState(
            auth: store.auth,
            sidebarJobFilterDefaults: sidebarJobFilterDefaults
        )
        let rootViewController = ReviewMonitorRootViewController(
            store: store,
            uiState: uiState,
            contentTransitionAnimator: contentTransitionAnimator,
            showSettings: showSettings
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

    private static func makeUIState(
        auth: CodexReviewAuthModel,
        sidebarJobFilterDefaults: UserDefaults?
    ) -> ReviewMonitorUIState {
        guard let sidebarJobFilterDefaults else {
            return ReviewMonitorUIState(auth: auth)
        }
        return ReviewMonitorUIState(
            auth: auth,
            sidebarJobFilter: ReviewMonitorSidebar.JobFilterPersistence.load(from: sidebarJobFilterDefaults),
            persistSidebarJobFilter: { filter in
                ReviewMonitorSidebar.JobFilterPersistence.save(filter, to: sidebarJobFilterDefaults)
            }
        )
    }
}

enum ReviewMonitorSidebar {}

extension ReviewMonitorSidebar {
enum JobFilterPersistence {
    static let defaultsKey = "CodexReviewKit.ReviewMonitor.sidebarJobFilter"

    static func load(from defaults: UserDefaults) -> SidebarJobFilter {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let filter = SidebarJobFilter(persistedValue: rawValue)
        else {
            return .all
        }
        return filter
    }

    static func save(_ filter: SidebarJobFilter, to defaults: UserDefaults) {
        defaults.set(filter.persistedValue, forKey: defaultsKey)
    }
}
}
