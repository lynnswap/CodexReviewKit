import AppKit
import Combine
import CodexReview
import SwiftUI

@MainActor
final class ReviewMonitorSignInViewController: NSHostingController<SignInView> {
    private var windowCancellable: AnyCancellable?

    init(store: CodexReviewStore) {
        super.init(rootView: SignInView(store: store))
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
}
