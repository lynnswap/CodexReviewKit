import AppKit
import Combine
import CodexReview
import SwiftUI

@MainActor
private final class ReviewMonitorSignInActionSource {
    var startAPIKeySignIn: (() -> Void)?

    func performAPIKeySignIn() {
        startAPIKeySignIn?()
    }
}

@MainActor
final class ReviewMonitorSignInViewController: NSHostingController<SignInView> {
    private let store: CodexReviewStore
    private let actionSource: ReviewMonitorSignInActionSource
    private var windowCancellable: AnyCancellable?
    private var apiKeySignInTask: Task<Void, Never>?
    private weak var apiKeyAlert: NSAlert?
    private weak var apiKeyPromptWindow: NSWindow?

    init(store: CodexReviewStore) {
        self.store = store
        let actionSource = ReviewMonitorSignInActionSource()
        self.actionSource = actionSource
        super.init(rootView: SignInView(
            store: store,
            startAPIKeySignIn: { actionSource.performAPIKeySignIn() }
        ))
        actionSource.startAPIKeySignIn = { [weak self] in
            self?.startAPIKeySignIn()
        }
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else {
            return
        }
        applyWindowPresentation(to: window)
    }

    override func viewWillDisappear() {
        cancelAPIKeySignIn()
        super.viewWillDisappear()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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

    func applyWindowPresentation(to window: NSWindow) {
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.title = ""
        window.subtitle = ""
    }

    func applyWindowPresentationIfPossible() {
        guard let window = view.window else {
            return
        }
        applyWindowPresentation(to: window)
    }

    private func startAPIKeySignIn() {
        guard apiKeySignInTask == nil,
              store.auth.isAuthenticating == false
        else {
            return
        }
        let window = view.window
        apiKeyPromptWindow = window
        apiKeySignInTask = Task { @MainActor [weak self, store] in
            defer {
                self?.apiKeyAlert = nil
                self?.apiKeyPromptWindow = nil
                self?.apiKeySignInTask = nil
            }
            guard Task.isCancelled == false else {
                return
            }
            guard let apiKey = await ReviewMonitorAPIKeyPrompt.request(
                window: window,
                submitTitle: "Sign In",
                didPresent: { [weak self] alert in self?.apiKeyAlert = alert }
            ), Task.isCancelled == false else {
                return
            }
            await store.performPrimaryAuthenticationAction(apiKey: apiKey)
        }
    }

    private func cancelAPIKeySignIn() {
        apiKeySignInTask?.cancel()
        guard let apiKeyAlert else {
            return
        }
        if let apiKeyPromptWindow {
            apiKeyPromptWindow.endSheet(
                apiKeyAlert.window,
                returnCode: .cancel
            )
        } else if NSApp.modalWindow === apiKeyAlert.window {
            NSApp.abortModal()
            apiKeyAlert.window.close()
        }
        self.apiKeyAlert = nil
    }
}

#if DEBUG
extension ReviewMonitorSignInViewController {
    var hasAPIKeySignInTaskForTesting: Bool {
        apiKeySignInTask != nil
    }

    func startAPIKeySignInForTesting() {
        startAPIKeySignIn()
    }

    func cancelAPIKeySignInForTesting() {
        cancelAPIKeySignIn()
    }
}
#endif
