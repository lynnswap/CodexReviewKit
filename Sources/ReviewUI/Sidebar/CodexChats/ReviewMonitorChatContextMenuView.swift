import CodexKit
import SwiftUI

@MainActor
struct ReviewMonitorChatContextMenuView: View {
    private var chat: CodexChat

    init(chat: CodexChat) {
        self.chat = chat
    }

    var body: some View {
        Button("Cancel") {
            cancel()
        }
        .disabled(isRunning == false)
    }

    private var isRunning: Bool {
        chat.status?.isActive == true
    }

    private func cancel() {
        Task {
            try? await chat.cancel()
        }
    }
}
