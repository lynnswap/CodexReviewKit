import AppKit
import CodexKit
import CodexReviewKit
import Foundation
import ObjectiveC
@_spi(PreviewSupport) import ReviewUI

nonisolated(unsafe) private var previewContentSourceAssociationKey: UInt8 = 0

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

    let uiState = ReviewMonitorUIState(previewSupportAuth: store.auth)
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
        previewContent: ReviewMonitorPreviewContentSource,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        previewContent.startStreaming(interval: .milliseconds(40))
        let uiState = ReviewMonitorUIState(previewSupportAuth: previewContent.store.auth)
        uiState.selectChat(id: previewContent.initialChatID)
        self.init(
            store: previewContent.store,
            uiState: uiState,
            codexModelSource: previewContent.codexModelSource,
            showSettings: showSettings,
            dependencyRetainer: previewContent
        )
        window?.contentViewController?.installPreviewContentSourceForTesting(previewContent)
    }
}

public extension NSViewController {
    func prepareForSwiftUIPreviewRendering() {
        guard let rootViewController = self as? ReviewMonitorRootViewController else {
            loadViewIfNeeded()
            view.layoutSubtreeIfNeeded()
            return
        }
        rootViewController.prepareForImmediateRenderingForTesting()
    }

    @discardableResult
    func appendPreviewChatLogStreamTickForTesting(after tick: Int = 0) async -> Int? {
        guard let previewContent = previewContentSourceForTesting else {
            return nil
        }
        return await previewContent.appendPreviewChatLogStreamTick(
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
}
