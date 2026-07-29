import AppKit
import CodexAppServerKit
import CodexDataKit
import CodexReviewKit
import OSLog
import SwiftUI

private let chatContextMenuLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "chat-context-menu"
)

@MainActor
struct ReviewMonitorChatArchiveConfirmation: Sendable {
    typealias Action = @MainActor @Sendable (_ chatID: CodexThreadID, _ title: String) async -> Bool

    private let action: Action

    init(action: @escaping Action) {
        self.action = action
    }

    func shouldArchive(chatID: CodexThreadID, title: String) async -> Bool {
        await action(chatID, title)
    }

    static let appKitAlert = ReviewMonitorChatArchiveConfirmation { _, title in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive Active Chat?"
        alert.informativeText = "\"\(title)\" is still running. Archive it?"
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
struct ReviewMonitorChatContextMenuView: View {
    private var chat: CodexChat
    private var store: CodexReviewStore
    private var archiveConfirmation: ReviewMonitorChatArchiveConfirmation

    init(
        chat: CodexChat,
        store: CodexReviewStore,
        archiveConfirmation: ReviewMonitorChatArchiveConfirmation = .appKitAlert
    ) {
        self.chat = chat
        self.store = store
        self.archiveConfirmation = archiveConfirmation
    }

    var body: some View {
        Button("Cancel") {
            cancel()
        }
        .disabled(cancellationCapability.isEnabled == false)

        Divider()

        Button("Archive") {
            archive()
        }
    }

    private func cancel() {
        let chatID = chat.id.rawValue
        let action = cancellationCapability.action
        Task {
            do {
                switch action {
                case .some(.reviewRun):
                    _ = try await store.cancelReview(chatID: chatID, cancellation: .userInterface())
                case .some(.directChat):
                    try await chat.cancel()
                case nil:
                    break
                }
            } catch {
                chatContextMenuLogger.error(
                    "Failed to cancel chat \(chatID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func archive() {
        let archiveConfirmation = archiveConfirmation
        Task { @MainActor in
            if chat.status?.isActive == true {
                let shouldArchive = await archiveConfirmation.shouldArchive(
                    chatID: chat.id,
                    title: chat.title
                )
                guard shouldArchive else {
                    return
                }
            }
            do {
                try await chat.archive()
            } catch {
                chatContextMenuLogger.error(
                    "Failed to archive chat \(chat.id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
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
