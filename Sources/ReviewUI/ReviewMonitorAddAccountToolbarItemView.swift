import AppKit
import Foundation

@MainActor
final class AddAccountToolbarItemView: NSView {
    enum Mode: Equatable {
        case add
        case progress
    }

#if DEBUG
    private struct StableModeWaiterForTesting {
        let mode: Mode
        let continuation: CheckedContinuation<Void, Never>
    }
#endif

    private var displayedMode: Mode = .add
    private var pendingMode: Mode?
    private var isAnimatingModeTransition = false

    private let rootStackView = NSStackView()
    private let addButton = NSButton()
    private let progressButton = AddAccountToolbarProgressButton()

#if DEBUG
    private var stableModeWaitersForTesting: [UUID: StableModeWaiterForTesting] = [:]
#endif

    init() {
        super.init(frame: .zero)
        configureHierarchy()
        applyPresentation(mode: .add, progressDetail: nil, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        rootStackView.fittingSize
    }

    private func configureHierarchy() {
        addButton.bezelStyle = .toolbar
        addButton.image = NSImage(
            systemSymbolName: "person.badge.plus",
            accessibilityDescription: "Add Account"
        )
        addButton.imagePosition = .imageOnly
        addButton.setButtonType(.momentaryPushIn)
        addButton.toolTip = "Add Account"
        addButton.setAccessibilityLabel("Add Account")

        rootStackView.orientation = .horizontal
        rootStackView.alignment = .centerY
        rootStackView.translatesAutoresizingMaskIntoConstraints = false
        rootStackView.addArrangedSubview(addButton)
        rootStackView.addArrangedSubview(progressButton)
        addSubview(rootStackView)

        NSLayoutConstraint.activate([
            rootStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStackView.topAnchor.constraint(equalTo: topAnchor),
            rootStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configureActions(
        target: AnyObject?,
        addAction: Selector?,
        cancelAction: Selector?
    ) {
        addButton.target = target
        addButton.action = addAction
        progressButton.target = target
        progressButton.action = cancelAction
    }

    func applyPresentation(
        mode targetMode: Mode,
        progressDetail detail: String?,
        animated: Bool
    ) {
        toolTip = nil
        progressButton.toolTip = targetMode == .progress ? "Cancel sign-in" : nil
        progressButton.setProgressDetailToolTip(detail)

        guard targetMode != displayedMode else {
            if isAnimatingModeTransition {
                pendingMode = targetMode
                return
            }
            pendingMode = nil
            applyMode(targetMode)
            return
        }

        pendingMode = targetMode
        guard animated, window != nil else {
            pendingMode = nil
            alphaValue = 1
            applyMode(targetMode)
            return
        }

        guard isAnimatingModeTransition == false else {
            return
        }

        animateModeTransition(to: targetMode)
    }

    private func applyMode(_ mode: Mode) {
        displayedMode = mode
        if pendingMode == mode {
            pendingMode = nil
        }
        let isAuthenticating = mode == .progress
        addButton.isHidden = isAuthenticating
        progressButton.isHidden = isAuthenticating == false

        if isAuthenticating {
            progressButton.startProgressAnimation()
        } else {
            progressButton.stopProgressAnimation()
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        notifyStableModeWaitersForTestingIfNeeded()
    }

    private func animateModeTransition(to targetMode: Mode) {
        isAnimatingModeTransition = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            MainActor.assumeIsolated {
                animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.applyMode(targetMode)
                self.alphaValue = 0

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.allowsImplicitAnimation = true
                    MainActor.assumeIsolated {
                        self.animator().alphaValue = 1
                    }
                } completionHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self: AddAccountToolbarItemView = self else {
                            return
                        }

                        self.isAnimatingModeTransition = false
                        if let pendingMode = self.pendingMode,
                           pendingMode != self.displayedMode
                        {
                            self.animateModeTransition(to: pendingMode)
                            return
                        }
                        self.notifyStableModeWaitersForTestingIfNeeded()
                    }
                }
            }
        }
    }
}

#if DEBUG
@MainActor
extension AddAccountToolbarItemView {
    var displayedModeForTesting: Mode {
        displayedMode
    }

    func waitForStableModeForTesting(_ mode: Mode) async {
        if isStableModeForTesting(mode) {
            return
        }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isStableModeForTesting(mode) {
                    continuation.resume()
                    return
                }
                stableModeWaitersForTesting[waiterID] = .init(
                    mode: mode,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelStableModeWaiterForTesting(waiterID)
            }
        }
    }

    private func isStableModeForTesting(_ mode: Mode) -> Bool {
        displayedMode == mode && pendingMode == nil && isAnimatingModeTransition == false
    }

    private func notifyStableModeWaitersForTestingIfNeeded() {
        guard stableModeWaitersForTesting.isEmpty == false else {
            return
        }

        let readyWaiterIDs = stableModeWaitersForTesting.compactMap { id, waiter in
            isStableModeForTesting(waiter.mode) ? id : nil
        }
        let readyContinuations = readyWaiterIDs.compactMap { id in
            stableModeWaitersForTesting.removeValue(forKey: id)?.continuation
        }
        for continuation in readyContinuations {
            continuation.resume()
        }
    }

    private func cancelStableModeWaiterForTesting(_ waiterID: UUID) {
        guard let waiter = stableModeWaitersForTesting.removeValue(forKey: waiterID) else {
            return
        }
        waiter.continuation.resume()
    }
}
#else
@MainActor
extension AddAccountToolbarItemView {
    private func notifyStableModeWaitersForTestingIfNeeded() {}
}
#endif

@MainActor
private final class AddAccountToolbarProgressButton: NSButton {
    private let contentStackView = NSStackView()
    private let progressIndicator = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "Cancel")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = contentStackView.fittingSize
        return NSSize(width: contentSize.width + 16, height: max(28, contentSize.height + 8))
    }

    private func configure() {
        bezelStyle = .toolbar
        title = ""
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        setAccessibilityLabel("Cancel Account Sign-In")

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel("Account Sign-In Progress")

        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byClipping

        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.spacing = 6
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.addArrangedSubview(progressIndicator)
        contentStackView.addArrangedSubview(titleLabel)

        addSubview(contentStackView)
        NSLayoutConstraint.activate([
            contentStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contentStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    func startProgressAnimation() {
        progressIndicator.startAnimation(nil)
    }

    func stopProgressAnimation() {
        progressIndicator.stopAnimation(nil)
    }

    func setProgressDetailToolTip(_ toolTip: String?) {
        progressIndicator.toolTip = toolTip
    }
}
