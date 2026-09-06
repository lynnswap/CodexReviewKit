import AppKit
import CodexReview

enum ReviewMonitorCodexUpdateNotification {
    static let availabilityChanged = Notification.Name(
        "CodexReviewKit.ReviewMonitor.codexUpdateAvailabilityChanged"
    )
    static let requested = Notification.Name(
        "CodexReviewKit.ReviewMonitor.codexUpdateRequested"
    )
    static let availableUserInfoKey = "available"
}

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
    private let uiState: ReviewMonitorUIState
    private let notificationCenter: NotificationCenter
    private var codexUpdateAvailabilityObserver: NSObjectProtocol?

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
        showSettings: (@MainActor () -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.init(
            store: store,
            contentTransitionAnimator: contentTransitionAnimator,
            frameAutosaveName: Self.frameAutosaveName,
            sidebarJobFilterDefaults: sidebarJobFilterDefaults,
            showSettings: showSettings,
            notificationCenter: notificationCenter
        )
    }

    init(
        store: CodexReviewStore,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator,
        frameAutosaveName: NSWindow.FrameAutosaveName,
        sidebarJobFilterDefaults: UserDefaults? = .standard,
        showSettings: (@MainActor () -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        let uiState = Self.makeUIState(
            auth: store.auth,
            sidebarJobFilterDefaults: sidebarJobFilterDefaults
        )
        let rootViewController = ReviewMonitorRootViewController(
            store: store,
            uiState: uiState,
            contentTransitionAnimator: contentTransitionAnimator,
            showSettings: showSettings,
            notificationCenter: notificationCenter
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
        self.uiState = uiState
        self.notificationCenter = notificationCenter
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(frameAutosaveName)
        observeCodexUpdateAvailability()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        stopObservingCodexUpdateAvailability()
    }

    private func observeCodexUpdateAvailability() {
        codexUpdateAvailabilityObserver = notificationCenter.addObserver(
            forName: ReviewMonitorCodexUpdateNotification.availabilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isAvailable = notification.userInfo?[
                ReviewMonitorCodexUpdateNotification.availableUserInfoKey
            ] as? Bool else {
                return
            }
            MainActor.assumeIsolated {
                self?.uiState.isCodexUpdateAvailable = isAvailable
            }
        }
    }

    private func stopObservingCodexUpdateAvailability() {
        guard let codexUpdateAvailabilityObserver else {
            return
        }
        notificationCenter.removeObserver(codexUpdateAvailabilityObserver)
        self.codexUpdateAvailabilityObserver = nil
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

#if DEBUG
extension ReviewMonitorWindowController {
    func stopObservingCodexUpdateAvailabilityForTesting() {
        stopObservingCodexUpdateAvailability()
    }
}
#endif

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
