#if DEBUG
import AppKit
import CodexReview
import SwiftUI

#Preview("Normal") {
    ReviewMonitorContentPreviewHost()
}

#Preview("Server Failed") {
    ReviewMonitorContentPreviewHost(
        serverState: .failed("The embedded server stopped responding.")
    )
}

@MainActor
private struct ReviewMonitorContentPreviewHost: NSViewControllerRepresentable {
    var authPhase: CodexReviewAuthModel.Phase = .signedOut
    var account: CodexAccount?
    var serverState: CodexReviewServerState = .running

    func makeNSViewController(context: Context) -> ReviewMonitorRootViewController {
        makeReviewMonitorPreviewContentViewControllerForPreview(
            authPhase: authPhase,
            account: account,
            serverState: serverState
        )
    }

    func updateNSViewController(
        _ nsViewController: ReviewMonitorRootViewController,
        context: Context
    ) {
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: ReviewMonitorRootViewController,
        context: Context
    ) -> CGSize? {
        guard
            let width = proposal.width,
            let height = proposal.height,
            width.isFinite,
            height.isFinite
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
#endif
