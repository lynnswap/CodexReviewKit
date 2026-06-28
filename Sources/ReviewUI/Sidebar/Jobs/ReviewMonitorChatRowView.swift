import Foundation
import SwiftUI

struct ReviewMonitorSidebarChatRow: Equatable {
    var id: String
    var title: String
    var model: String?
    var subtitle: String?
    var startedAt: Date?
    var endedAt: Date?
    var isRunning: Bool

    init(
        id: String,
        title: String,
        model: String?,
        subtitle: String?,
        startedAt: Date?,
        endedAt: Date?,
        isRunning: Bool
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isRunning = isRunning
    }

    init(chat: ReviewMonitorCodexSidebarSnapshot.Chat) {
        self.init(
            id: chat.id.rawValue,
            title: chat.title,
            model: chat.model,
            subtitle: chat.preview?.trimmedNonEmpty,
            startedAt: chat.isRunning ? chat.activityDate : nil,
            endedAt: chat.isRunning ? nil : chat.activityDate,
            isRunning: chat.isRunning
        )
    }
}

struct ReviewMonitorChatRowContentView: View {
    var row: ReviewMonitorSidebarChatRow

    var body: some View {
        Label {
            VStack {
                HStack {
                    Text(row.title)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    ReviewMonitorChatRowTimerLabel(row: row)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                .lineLimit(1)
                HStack {
                    if let model = row.model {
                        Text(model)
                    }
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                    }
                    Spacer(minLength: 0)
                }
                .textScale(.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            ZStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.clear)
                if row.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .animation(.default, value: row.isRunning)
            .padding(.leading, SidebarLayout.disclosureGutterWidth)
        }
        .transaction(value: row.id) { transaction in
            transaction.disablesAnimations = true
        }
    }
}

struct ReviewMonitorChatRowView: View {
    var node: ReviewMonitorCodexSidebarOutlineNode

    var row: ReviewMonitorSidebarChatRow? {
        guard case .chat(let chat) = node.item else {
            return nil
        }
        return ReviewMonitorSidebarChatRow(chat: chat)
    }

    var body: some View {
        if let row {
            ReviewMonitorChatRowContentView(row: row)
        }
    }
}

struct ReviewMonitorChatRowTimerLabel: View {
    var row: ReviewMonitorSidebarChatRow

    var body: some View {
        if let startedAt = row.startedAt {
            Text(
                timerInterval: startedAt...(row.endedAt ?? .distantFuture),
                pauseTime: row.endedAt,
                countsDown: false,
                showsHours: true
            )
            .monospacedDigit()
        }
    }
}

#if DEBUG
    #Preview {
        NavigationSplitView {
            List {
                Section("workspace-alpha") {
                    ReviewMonitorChatRowContentView(
                        row: ReviewMonitorSidebarChatRow(
                            id: "preview-running",
                            title: "Uncommitted changes",
                            model: "gpt-5.5",
                            subtitle: "Inspecting recent changes",
                            startedAt: Date(timeIntervalSinceNow: -640),
                            endedAt: nil,
                            isRunning: true
                        )
                    )
                    ReviewMonitorChatRowContentView(
                        row: ReviewMonitorSidebarChatRow(
                            id: "preview-completed",
                            title: "Base branch: main",
                            model: "gpt-5.5-codex",
                            subtitle: "No findings",
                            startedAt: Date(timeIntervalSinceNow: -3_600),
                            endedAt: Date(timeIntervalSinceNow: -2_900),
                            isRunning: false
                        )
                    )
                }
            }
            .frame(minWidth: 320)
        } detail: {
            ContentUnavailableView {
                Text(verbatim: "Preview")
            }
        }
    }
#endif

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
