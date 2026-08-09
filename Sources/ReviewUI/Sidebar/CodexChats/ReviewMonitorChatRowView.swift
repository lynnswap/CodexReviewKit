import Foundation
import SwiftUI
import CodexAppServerKit
import CodexDataKit
import CodexReviewKit

@MainActor
struct ReviewMonitorChatRowPresentation: Equatable {
    enum Timing: Equatable {
        case elapsed(since: Date)
        case relative(to: Date)
    }

    enum Symbol: Equatable {
        case progress
        case succeeded
        case failed
        case cancelled
        case none
    }

    let title: String
    let statusText: String
    let timing: Timing?
    let symbol: Symbol

    init(chat: CodexChat, reviewRun: ReviewRunRecord?) {
        title = reviewRun?.targetSummary.trimmedNonEmpty
            ?? Self.gitLabel(chat.gitInfo)
            ?? chat.title

        guard let reviewRun else {
            if chat.status?.isActive == true {
                statusText = Self.isReviewSource(chat) ? "Reviewing" : "Running"
                timing = chat.activityDate.map(Timing.elapsed)
                symbol = .progress
            } else {
                statusText = Self.sourceLabel(chat)
                timing = chat.activityDate.map(Timing.relative)
                symbol = .none
            }
            return
        }

        let presentation = reviewRun.presentation
        switch presentation.lifecycle {
        case .queued:
            statusText = "Queued"
            symbol = .none
        case .starting:
            statusText = "Starting"
            symbol = .progress
        case .running:
            statusText = "Reviewing"
            symbol = .progress
        case .waitingForNetwork:
            statusText = "Waiting for network"
            symbol = .progress
        case .preparingRestart, .restarting:
            statusText = "Restarting"
            symbol = .progress
        case .cancelling:
            statusText = "Cancelling"
            symbol = .progress
        case .succeeded:
            statusText = "Review complete"
            symbol = .succeeded
        case .failed:
            statusText = "Review failed"
            symbol = .failed
        case .cancelled:
            statusText = "Cancelled"
            symbol = .cancelled
        }

        if let endedAt = reviewRun.core.endedAt {
            timing = .relative(to: endedAt)
        } else if let startedAt = reviewRun.core.startedAt {
            timing = .elapsed(since: startedAt)
        } else {
            timing = chat.activityDate.map(Timing.relative)
        }
    }

    private static func gitLabel(_ gitInfo: CodexThreadGitInfo?) -> String? {
        let branch = gitInfo?.branch?.trimmedNonEmpty
        let sha = gitInfo?.sha?.trimmedNonEmpty.map { String($0.prefix(8)) }
        switch (branch, sha) {
        case (.some(let branch), .some(let sha)):
            return "\(branch) · \(sha)"
        case (.some(let branch), nil):
            return branch
        case (nil, .some(let sha)):
            return sha
        case (nil, nil):
            return nil
        }
    }

    private static func isReviewSource(_ chat: CodexChat) -> Bool {
        if let source = chat.source, case .subAgent(.review) = source {
            return true
        }
        return chat.sourceKind == .subAgentReview
    }

    private static func sourceLabel(_ chat: CodexChat) -> String {
        if let source = chat.source {
            switch source {
            case .cli:
                return "CLI"
            case .vscode:
                return "VS Code"
            case .exec:
                return "Exec"
            case .appServer:
                return "Codex"
            case .custom(let value):
                guard let value = value.trimmedNonEmpty else {
                    return "Custom"
                }
                switch value.lowercased() {
                case "atlas":
                    return "Atlas"
                case "chatgpt":
                    return "ChatGPT"
                default:
                    return value
                }
            case .subAgent(.review):
                return "Review"
            case .subAgent(.compact):
                return "Compact"
            case .subAgent(.threadSpawn), .subAgent(.other):
                return "Sub-agent"
            case .subAgent(.memoryConsolidation):
                return "Memory"
            case .unknown:
                return "Thread"
            }
        }

        let sourceKind = chat.sourceKind
        if sourceKind == .cli { return "CLI" }
        if sourceKind == .vscode { return "VS Code" }
        if sourceKind == .exec { return "Exec" }
        if sourceKind == .appServer { return "Codex" }
        if sourceKind == .subAgentReview { return "Review" }
        if sourceKind == .subAgentCompact { return "Compact" }
        if sourceKind == .subAgent || sourceKind == .subAgentThreadSpawn
            || sourceKind == .subAgentOther
        {
            return "Sub-agent"
        }
        return "Thread"
    }
}

@MainActor
struct ReviewMonitorChatRowView: View {
    var chat: CodexChat
    var store: CodexReviewStore

    var body: some View {
        let reviewRun = store.reviewRun(forReviewChatID: chat.id.rawValue)
        let presentation = ReviewMonitorChatRowPresentation(chat: chat, reviewRun: reviewRun)

        Label {
            VStack(alignment: .leading) {
                Text(presentation.title)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(presentation.statusText)
                    Spacer(minLength: 4)
                    timingText(presentation.timing)
                }
                .textScale(.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            ZStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.clear)
                switch presentation.symbol {
                case .progress:
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                case .cancelled:
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                case .none:
                    EmptyView()
                }
            }
            .animation(.default, value: presentation.symbol)
            .padding(.leading, SidebarLayout.disclosureGutterWidth)
        }
        .transaction(value: chat.id.rawValue) { transaction in
            transaction.disablesAnimations = true
        }
        .help(presentation.title)
    }

    @ViewBuilder
    private func timingText(_ timing: ReviewMonitorChatRowPresentation.Timing?) -> some View {
        switch timing {
        case .elapsed(let startedAt):
            Text(
                timerInterval: startedAt...(.distantFuture),
                pauseTime: nil,
                countsDown: false,
                showsHours: true
            )
            .monospacedDigit()
            .layoutPriority(1)
        case .relative(let date):
            Text(date, style: .relative)
                .layoutPriority(1)
        case nil:
            EmptyView()
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
                    Text("Uncommitted changes")
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("Waiting for network")
                        Spacer(minLength: 4)
                        Text(
                            timerInterval: Date(timeIntervalSince1970: 0)...(.distantFuture),
                            pauseTime: nil,
                            countsDown: false,
                            showsHours: true
                        )
                        .monospacedDigit()
                        .layoutPriority(1)
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
