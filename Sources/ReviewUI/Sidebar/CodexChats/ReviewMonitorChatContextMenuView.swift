import CodexKit
import SwiftUI

@MainActor
struct ReviewMonitorChatContextMenuView: View {
    private enum Chat {
        case codex(CodexChat)
        case preview(ReviewMonitorPreviewChat)
    }

    private var chat: Chat

    init(chat: CodexChat) {
        self.chat = .codex(chat)
    }

    init(previewChat: ReviewMonitorPreviewChat) {
        self.chat = .preview(previewChat)
    }

    var body: some View {
        Button("Cancel") {
            cancel()
        }
        .disabled(isRunning == false)
    }

    private var isRunning: Bool {
        switch chat {
        case .codex(let chat):
            chat.status?.isActive == true
        case .preview(let chat):
            chat.isRunning
        }
    }

    private func cancel() {
        switch chat {
        case .codex(let chat):
            Task {
                try? await chat.cancel()
            }
        case .preview(let chat):
            chat.cancel()
        }
    }
}
