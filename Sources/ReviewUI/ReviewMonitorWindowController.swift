import AppKit
import CodexKit
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
            codexModelSource: nil,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            showSettings: nil
        )
    }

    public convenience init(
        store: CodexReviewStore,
        codexModelContext: CodexModelContext
    ) {
        self.init(
            store: store,
            codexModelSource: ReviewMonitorCodexModelSource(modelContext: codexModelContext),
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
            codexModelSource: nil,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            showSettings: showSettings
        )
    }

    @_spi(PreviewSupport)
    public convenience init(
        store: CodexReviewStore,
        codexModelSource: ReviewMonitorCodexModelSource,
        showSettings: @escaping @MainActor () -> Void
    ) {
        self.init(
            store: store,
            codexModelSource: codexModelSource,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            showSettings: showSettings
        )
    }

    convenience init(
        store: CodexReviewStore,
        codexModelSource: ReviewMonitorCodexModelSource? = nil,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator,
        initialSelection: ReviewMonitorSelection? = nil,
        sidebarReviewChatFilterDefaults: UserDefaults? = .standard,
        showSettings: (@MainActor () -> Void)? = nil,
        dependencyRetainer: AnyObject? = nil,
        appendPreviewChatLogStreamTickHandler: (@MainActor (Int) async -> Int?)? = nil
    ) {
        self.init(
            store: store,
            codexModelSource: codexModelSource,
            contentTransitionAnimator: contentTransitionAnimator,
            initialSelection: initialSelection,
            frameAutosaveName: Self.frameAutosaveName,
            sidebarReviewChatFilterDefaults: sidebarReviewChatFilterDefaults,
            showSettings: showSettings,
            dependencyRetainer: dependencyRetainer,
            appendPreviewChatLogStreamTickHandler: appendPreviewChatLogStreamTickHandler
        )
    }

    init(
        store: CodexReviewStore,
        codexModelSource: ReviewMonitorCodexModelSource? = nil,
        contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator,
        initialSelection: ReviewMonitorSelection? = nil,
        frameAutosaveName: NSWindow.FrameAutosaveName,
        sidebarReviewChatFilterDefaults: UserDefaults? = .standard,
        showSettings: (@MainActor () -> Void)? = nil,
        dependencyRetainer: AnyObject? = nil,
        appendPreviewChatLogStreamTickHandler: (@MainActor (Int) async -> Int?)? = nil
    ) {
        let uiState = Self.makeUIState(
            auth: store.auth,
            sidebarReviewChatFilterDefaults: sidebarReviewChatFilterDefaults
        )
        if uiState.selection == nil {
            uiState.selection = initialSelection
        }
        let rootViewController = ReviewMonitorRootViewController(
            store: store,
            uiState: uiState,
            codexModelSource: codexModelSource,
            contentTransitionAnimator: contentTransitionAnimator,
            showSettings: showSettings,
            dependencyRetainer: dependencyRetainer,
            appendPreviewChatLogStreamTickHandler: appendPreviewChatLogStreamTickHandler
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
        sidebarReviewChatFilterDefaults: UserDefaults?
    ) -> ReviewMonitorUIState {
        guard let sidebarReviewChatFilterDefaults else {
            return ReviewMonitorUIState(auth: auth)
        }
        return ReviewMonitorUIState(
            auth: auth,
            sidebarReviewChatFilter: ReviewMonitorSidebar.ReviewChatFilterPersistence.load(from: sidebarReviewChatFilterDefaults),
            persistSidebarReviewChatFilter: { filter in
                ReviewMonitorSidebar.ReviewChatFilterPersistence.save(filter, to: sidebarReviewChatFilterDefaults)
            }
        )
    }
}

@_spi(PreviewSupport)
public extension ReviewMonitorWindowController {
    convenience init(
        previewContent: ReviewMonitorPreviewContentSource,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        previewContent.startStreaming(interval: .milliseconds(40))
        self.init(
            store: previewContent.store,
            codexModelSource: previewContent.codexModelSource,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            initialSelection: previewContent.initialSelection,
            showSettings: showSettings,
            dependencyRetainer: previewContent,
            appendPreviewChatLogStreamTickHandler: { tick in
                let nextTick = await previewContent.appendPreviewChatLogStreamTick(after: tick)
                return nextTick
            }
        )
    }

    convenience init(
        previewStore store: CodexReviewStore,
        codexModelSource: ReviewMonitorCodexModelSource? = nil,
        initialChatID: CodexThreadID? = nil,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        self.init(
            store: store,
            codexModelSource: codexModelSource,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            initialSelection: initialChatID.map(ReviewMonitorSelection.chat),
            showSettings: showSettings
        )
    }
}

enum ReviewMonitorSidebar {}

extension ReviewMonitorSidebar {
    enum ReviewChatFilterPersistence {
        static let defaultsKey = "CodexReviewKit.ReviewMonitor.sidebarReviewChatFilter"

        static func load(from defaults: UserDefaults) -> SidebarReviewChatFilter {
            guard let rawValue = defaults.string(forKey: defaultsKey),
                  let filter = SidebarReviewChatFilter(persistedValue: rawValue)
            else {
                return .all
            }
            return filter
        }

        static func save(_ filter: SidebarReviewChatFilter, to defaults: UserDefaults) {
            defaults.set(filter.persistedValue, forKey: defaultsKey)
        }
    }
}
