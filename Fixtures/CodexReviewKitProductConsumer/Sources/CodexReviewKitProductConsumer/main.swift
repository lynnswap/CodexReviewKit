import AppKit
import CodexReview
import CodexReviewHost
import ReviewUI
import TextTransitions

@main
@MainActor
struct CodexReviewKitProductConsumer {
    static func main() async throws {
        let lifecycleInitializer: (
            ReviewJobState,
            Int?,
            Date?,
            Date?,
            ReviewCancellation?,
            String?
        ) -> ReviewJobCore.Lifecycle = ReviewJobCore.Lifecycle.init(
            status:exitCode:startedAt:endedAt:cancellation:errorMessage:
        )
        let parsedResult = ParsedReviewResult.parse(finalReviewText: "No findings.")
        let core = ReviewJobCore(
            lifecycle: lifecycleInitializer(.succeeded, nil, nil, nil, nil, nil),
            output: .init(
                summary: "Review completed.",
                hasFinalReview: true,
                lastAgentMessage: "No findings.",
                reviewResult: parsedResult
            )
        )
        guard core.isTerminal,
              core.reviewText == "No findings.",
              parsedResult.state == .noFindings
        else {
            fatalError("CodexReview public review result contract drifted.")
        }
        guard core.lifecycle.terminal == nil,
              ReviewTerminalRecord.completed.kind == .completed,
              ReviewTerminalRecord.failed(message: nil).kind == .failed,
              ReviewTerminalRecord.interrupted(
                .requested(.mcpClient(message: "Stop"))
              ).kind == .interrupted
        else {
            fatalError("CodexReview public terminal contract drifted.")
        }

        let preferences = CodexReviewRuntime.Preferences(
            mcpHost: "localhost",
            mcpPort: 9417,
            mcpPath: "/mcp"
        )
        guard preferences.mcpHost == "localhost",
              preferences.mcpPort == 9417,
              preferences.mcpPath == "/mcp"
        else {
            fatalError("CodexReviewHost public preferences contract drifted.")
        }

        let store = CodexReviewStore.makePreviewStore()
        let windowController = ReviewMonitorWindowController(store: store)
        guard windowController.window != nil else {
            fatalError("ReviewUI public window composition failed.")
        }

        let transitionView = TextTransitionView(
            text: NSAttributedString(string: "42"),
            contentTransition: .numericText(),
            widthReservation: .natural,
            motionPolicy: .disabled
        )
        transitionView.setText(NSAttributedString(string: "43"), animated: false)
        guard transitionView.text.string == "43" else {
            fatalError("TextTransitions public rendering contract drifted.")
        }

        try await store.close()
        withExtendedLifetime((store, windowController, transitionView)) {}
        print("CodexReviewKit public product consumer passed.")
    }
}
