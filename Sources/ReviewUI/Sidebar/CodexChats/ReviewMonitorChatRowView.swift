import Foundation
import SwiftUI
import CodexKit

@MainActor
struct ReviewMonitorChatRowView: View {
    var chat: CodexChat

    var body: some View {
        let isRunning = chat.status?.isActive == true
        let startedAt = isRunning ? chat.activityDate : nil

        Label {
            VStack {
                HStack {
                    Text(chat.title)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let startedAt {
                        Text(
                            timerInterval: startedAt...(.distantFuture),
                            pauseTime: nil,
                            countsDown: false,
                            showsHours: true
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    }
                }
                .lineLimit(1)
                HStack {
                    Text(chat.modelProvider?.trimmedNonEmpty ?? "")
                    Text(chat.preview?.trimmedNonEmpty ?? "")
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
        .transaction(value: chat.id.rawValue) { transaction in
            transaction.disablesAnimations = true
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
    ReviewMonitorChatRowView.measureMeasuredHeight()
}

@MainActor
extension ReviewMonitorChatRowView {
    static func measureMeasuredHeight() -> CGFloat {
        let hostingView = NSHostingView(
            rootView: Label {
                VStack {
                    HStack {
                        Text("Uncommitted changes")
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(
                            timerInterval: Date(timeIntervalSince1970: 0)...(.distantFuture),
                            pauseTime: nil,
                            countsDown: false,
                            showsHours: true
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    }
                    .lineLimit(1)
                    HStack {
                        Text("gpt-5.5")
                        Text("Review output preview")
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
                    ProgressView()
                        .controlSize(.mini)
                }
                .animation(.default, value: true)
                .padding(.leading, SidebarLayout.disclosureGutterWidth)
            }
            .transaction(value: "row-height-measurement") { transaction in
                transaction.disablesAnimations = true
            }
        )
        return ceil(hostingView.fittingSize.height)
    }
}
