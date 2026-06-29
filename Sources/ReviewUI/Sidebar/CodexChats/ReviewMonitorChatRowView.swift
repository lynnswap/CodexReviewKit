import Foundation
import SwiftUI
import CodexKit

@MainActor
private struct ReviewMonitorChatRowContent: View {
    var chat: CodexChat

    var body: some View {
        ReviewMonitorChatRowLayout(
            id: chat.id.rawValue,
            title: chat.title,
            model: chat.modelProvider,
            subtitle: chat.preview?.trimmedNonEmpty,
            startedAt: chat.status?.isActive == true ? chat.activityDate : nil,
            endedAt: nil,
            isRunning: chat.status?.isActive == true
        )
    }
}

@MainActor
private struct ReviewMonitorChatRowLayout: View {
    var id: String
    var title: String
    var model: String?
    var subtitle: String?
    var startedAt: Date?
    var endedAt: Date?
    var isRunning: Bool

    var body: some View {
        Label {
            VStack {
                HStack {
                    Text(title)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    ReviewMonitorChatRowTimerLabel(startedAt: startedAt, endedAt: endedAt)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                .lineLimit(1)
                HStack {
                    if let model {
                        Text(model)
                    }
                    if let subtitle {
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
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .animation(.default, value: isRunning)
            .padding(.leading, SidebarLayout.disclosureGutterWidth)
        }
        .transaction(value: id) { transaction in
            transaction.disablesAnimations = true
        }
    }
}

@MainActor
struct ReviewMonitorChatRowView: View {
    var chat: CodexChat

    var body: some View {
        ReviewMonitorChatRowContent(chat: chat)
    }
}

@MainActor
struct ReviewMonitorChatRowTimerLabel: View {
    var startedAt: Date?
    var endedAt: Date?

    var body: some View {
        if let startedAt {
            Text(
                timerInterval: startedAt...(endedAt ?? .distantFuture),
                pauseTime: endedAt,
                countsDown: false,
                showsHours: true
            )
            .monospacedDigit()
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension CodexChat {
    var activityDate: Date? {
        recencyAt ?? updatedAt
    }
}

@MainActor
package func measuredReviewMonitorChatRowHeight() -> CGFloat {
    ReviewMonitorChatRowLayout.measureMeasuredHeight()
}

@MainActor
extension ReviewMonitorChatRowLayout {
    static func measureMeasuredHeight() -> CGFloat {
        let hostingView = NSHostingView(
            rootView: ReviewMonitorChatRowLayout(
                id: "row-height-measurement",
                title: "Uncommitted changes",
                model: "gpt-5.5",
                subtitle: "Review output preview",
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: nil,
                isRunning: true
            )
        )
        return ceil(hostingView.fittingSize.height)
    }
}
