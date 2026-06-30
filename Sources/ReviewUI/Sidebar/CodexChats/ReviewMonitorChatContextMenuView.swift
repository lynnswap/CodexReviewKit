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
        .disabled(cancellationCapability.isEnabled == false)
    }

    private func cancel() {
        let chatID = chat.id.rawValue
        let action = cancellationCapability.action
        Task {
            switch action {
            case .some(.reviewRun):
                _ = try? await store.cancelReview(chatID: chatID, cancellation: .userInterface())
            case .some(.directChat):
                _ = try? await chat.cancel()
            case nil:
                break
            }
        }
    }

    private var cancellationCapability: CodexChatCancellationCapability {
        store.chatCancellationCapability(
            forChatID: chat.id.rawValue,
            isChatActive: chat.status?.isActive == true
        )
    }
}
