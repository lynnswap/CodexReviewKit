import Foundation
import SwiftUI
import CodexReviewKit

struct ReviewMonitorSidebarChatRow: Equatable {
    var id: String
    var title: String
    var model: String?
    var subtitle: String?
    var startedAt: Date?
    var endedAt: Date?
    var isRunning: Bool

    @MainActor
    init(job: CodexReviewJob) {
        self.id = job.id
        self.title = job.displayTitle
        self.model = job.core.run.model
        self.subtitle = Self.subtitleText(for: job)
        self.startedAt = job.core.lifecycle.startedAt
        self.endedAt = job.core.lifecycle.endedAt
        self.isRunning = job.core.lifecycle.status == .running
    }

    @MainActor
    private static func subtitleText(for job: CodexReviewJob) -> String? {
        if job.core.output.hasFinalReview,
           let finalReview = job.core.output.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           finalReview.isEmpty == false
        {
            return finalReview
        }
        if job.core.lifecycle.status == .cancelled {
            let reviewText = job.reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return reviewText.isEmpty ? nil : reviewText
        }
        if let errorMessage = job.core.lifecycle.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           errorMessage.isEmpty == false
        {
            let summary = job.core.output.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? errorMessage : summary
        }
        guard let lastAgentMessage = job.core.output.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              lastAgentMessage.isEmpty == false
        else {
            return nil
        }
        return lastAgentMessage
    }
}

@MainActor
final class ReviewMonitorSidebarReviewChatRow {
    let jobID: String
    private(set) var sessionID: String
    private(set) var cwd: String
    private(set) var chat: ReviewMonitorCodexSidebarSnapshot.Chat?
    private(set) var presentation: ReviewMonitorSidebarChatRow
    private(set) var isTerminal: Bool
    private(set) var cancellationRequested: Bool

    init(job: CodexReviewJob) {
        self.jobID = job.id
        self.sessionID = job.sessionID
        self.cwd = job.cwd
        self.chat = job.reviewChatSelection
        self.presentation = ReviewMonitorSidebarChatRow(job: job)
        self.isTerminal = job.isTerminal
        self.cancellationRequested = job.cancellationRequested
    }

    func update(from job: CodexReviewJob) {
        sessionID = job.sessionID
        cwd = job.cwd
        chat = job.reviewChatSelection
        presentation = ReviewMonitorSidebarChatRow(job: job)
        isTerminal = job.isTerminal
        cancellationRequested = job.cancellationRequested
    }
}

struct ReviewMonitorChatRowView: View {
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
    @Previewable @State var store = ReviewMonitorPreviewContent.makeStore()
    NavigationSplitView {
        List {
            ForEach(store.orderedWorkspaces, id: \.cwd) { workspace in
                Section(workspace.displayTitle) {
                    ForEach(store.orderedJobs(in: workspace)) { job in
                        NavigationLink{
                            
                        }label:{
                            ReviewMonitorChatRowView(row: ReviewMonitorSidebarChatRow(job: job))
                        }
                    }
                }
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
