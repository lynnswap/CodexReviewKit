import AppKit
import CodexKit
import CodexReviewKit
import Foundation
import ObjectiveC
import ReviewUI

nonisolated(unsafe) private var previewContentSourceAssociationKey: UInt8 = 0
nonisolated(unsafe) private var previewContentDependenciesAssociationKey: UInt8 = 0

@MainActor
func makeReviewMonitorPreviewContentViewController() -> NSViewController {
    makeReviewMonitorPreviewContentViewControllerForPreview()
}

@MainActor
func makeReviewMonitorPreviewContentViewControllerForPreview(
    authPhase: CodexReviewAuthModel.Phase = .signedOut,
    account: CodexReviewAccount? = nil,
    serverState: CodexReviewServerState = .running,
    previewContent: ReviewMonitorPreviewContentSource? = nil
) -> NSViewController {
    let store: CodexReviewStore
    let resolvedPreviewContent: ReviewMonitorPreviewContentSource?
    let ownsPreviewContent = previewContent == nil
    switch serverState {
    case .running:
        if let previewContent {
            resolvedPreviewContent = previewContent
            store = previewContent.store
        } else {
            let previewContent = ReviewMonitorPreviewContent.makeContentSource()
            resolvedPreviewContent = previewContent
            store = previewContent.store
        }
    case .failed, .starting, .stopped:
        resolvedPreviewContent = nil
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
    uiState.selectChat(id: resolvedPreviewContent?.initialChatID)
    if let resolvedPreviewContent {
        if ownsPreviewContent {
            resolvedPreviewContent.startStreaming(interval: .milliseconds(40))
        } else {
            resolvedPreviewContent.start()
        }
    }
    let viewController = ReviewMonitorRootViewController(
        store: store,
        uiState: uiState,
        codexModelSource: resolvedPreviewContent?.codexModelSource,
        dependencyRetainer: resolvedPreviewContent
    )
    viewController.installPreviewContentSourceForTesting(resolvedPreviewContent)
    return viewController
}

public extension ReviewMonitorWindowController {
    convenience init(
        previewSupportStore store: CodexReviewStore,
        codexModelSource: ReviewMonitorCodexModelSource,
        showSettings: @escaping @MainActor () -> Void
    ) {
        guard let previewDependencies = store.previewContentDependenciesForPreviewSupport else {
            self.init(
                store: store,
                codexModelSource: codexModelSource,
                showSettings: showSettings
            )
            return
        }
        previewDependencies.startStreaming(interval: .milliseconds(40))
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.selectChat(id: previewDependencies.initialChatID)
        self.init(
            store: store,
            uiState: uiState,
            codexModelSource: previewDependencies.codexModelSource,
            showSettings: showSettings,
            dependencyRetainer: previewDependencies
        )
        window?.contentViewController?.installPreviewContentDependenciesForTesting(previewDependencies)
    }
}

public extension NSViewController {
    func prepareForSwiftUIPreviewRendering() {
        guard let rootViewController = self as? ReviewMonitorRootViewController else {
            loadViewIfNeeded()
            view.layoutSubtreeIfNeeded()
            return
        }
        rootViewController.prepareForImmediateRenderingForPreviewSupport()
    }

    @discardableResult
    func appendPreviewChatLogStreamTickForTesting(after tick: Int = 0) async -> Int? {
        if let previewContent = previewContentSourceForTesting {
            return await previewContent.appendPreviewChatLogStreamTick(
                after: tick,
                emitsNotifications: true
            )
        }
        guard let previewDependencies = previewContentDependenciesForTesting else {
            return nil
        }
        return await previewDependencies.appendPreviewChatLogStreamTick(
            after: tick,
            emitsNotifications: true
        )
    }
}

private extension NSViewController {
    var previewContentSourceForTesting: ReviewMonitorPreviewContentSource? {
        objc_getAssociatedObject(
            self,
            &previewContentSourceAssociationKey
        ) as? ReviewMonitorPreviewContentSource
    }

    func installPreviewContentSourceForTesting(_ previewContent: ReviewMonitorPreviewContentSource?) {
        objc_setAssociatedObject(
            self,
            &previewContentSourceAssociationKey,
            previewContent,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    var previewContentDependenciesForTesting: ReviewMonitorPreviewContentDependencies? {
        objc_getAssociatedObject(
            self,
            &previewContentDependenciesAssociationKey
        ) as? ReviewMonitorPreviewContentDependencies
    }

    func installPreviewContentDependenciesForTesting(
        _ dependencies: ReviewMonitorPreviewContentDependencies?
    ) {
        objc_setAssociatedObject(
            self,
            &previewContentDependenciesAssociationKey,
            dependencies,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
