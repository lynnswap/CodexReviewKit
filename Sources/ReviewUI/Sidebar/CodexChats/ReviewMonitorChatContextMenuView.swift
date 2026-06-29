import CodexKit
import CodexReviewKit
import SwiftUI

@MainActor
struct ReviewMonitorChatContextMenuView: View {
    private var chat: CodexChat
    private var store: CodexReviewStore

    init(chat: CodexChat, store: CodexReviewStore) {
        self.chat = chat
        self.store = store
    }

    var body: some View {
        Button("Cancel") {
            cancel()
        }
        .disabled(isRunning == false)
    }

    private var isRunning: Bool {
        let chatID = chat.id.rawValue
        return store.hasCancellableReview(forChatID: chatID)
            || chat.status?.isActive == true
    }

    private func cancel() {
        let chatID = chat.id.rawValue
        Task {
            if store.hasCancellableReview(forChatID: chatID) {
                _ = try? await store.cancelReview(chatID: chatID, cancellation: .userInterface())
            } else if shouldCancelActiveChatDirectly(chatID: chatID) {
                _ = try? await chat.cancel()
            }
        }
    }

    private func shouldCancelActiveChatDirectly(chatID: String) -> Bool {
        guard chat.status?.isActive == true else {
            return false
        }
        return store.hasNonTerminalReviewRun(forChatID: chatID) == false
    }
}
