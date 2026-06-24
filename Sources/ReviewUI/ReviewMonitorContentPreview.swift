#if DEBUG
import AppKit
import CodexReviewKit
import SwiftUI

#Preview("Normal") {
    ReviewMonitorContentPreviewHost()
}

#Preview("Server Failed") {
    ReviewMonitorContentPreviewHost(
        serverState: .failed("The embedded server stopped responding.")
    )
}

#Preview("Command Output") {
    ReviewMonitorContentPreviewHost(previewScenario: .commandOutput)
}

@MainActor
private struct ReviewMonitorContentPreviewHost: NSViewControllerRepresentable {
    enum PreviewScenario {
        case normal
        case commandOutput
    }

    var previewScenario: PreviewScenario = .normal
    var authPhase: CodexReviewAuthModel.Phase = .signedOut
    var account: CodexAccount?
    var serverState: CodexReviewServerState = .running

    func makeNSViewController(context: Context) -> ReviewMonitorRootViewController {
        makeReviewMonitorPreviewContentViewControllerForPreview(
            authPhase: authPhase,
            account: account,
            serverState: serverState,
            previewStore: previewStore()
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

    private func previewStore() -> CodexReviewStore? {
        guard case .running = serverState else {
            return nil
        }
        switch previewScenario {
        case .normal:
            return nil
        case .commandOutput:
            return ReviewMonitorPreviewContent.makeCommandOutputStore()
        }
    }
}
#endif
