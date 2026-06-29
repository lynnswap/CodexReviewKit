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
        if store.hasCancellableReview(forChatID: chatID) {
            return true
        }
        if store.hasReviewRun(forChatID: chatID) {
            return false
        }
        return chat.status?.isActive == true
    }

    private func cancel() {
        let chatID = chat.id.rawValue
        Task {
            if store.hasCancellableReview(forChatID: chatID) {
                _ = try? await store.cancelReview(chatID: chatID, cancellation: .userInterface())
            } else if store.hasReviewRun(forChatID: chatID) == false {
                _ = try? await chat.cancel()
            }
        }
    }
}
