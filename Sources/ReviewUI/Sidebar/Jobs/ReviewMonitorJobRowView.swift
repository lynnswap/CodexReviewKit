import Foundation
import SwiftUI
import CodexReviewKit

struct ReviewMonitorJobRowView: View {
    var job: CodexReviewJob

    var body: some View {
        Label {
            VStack {
                HStack {
                    Text(job.displayTitle)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    TimerLabelView(job: job)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                .lineLimit(1)
                HStack {
                    if let model = job.core.run.model {
                        Text(model)
                    }
                    if let subtitle = subtitleText {
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
                if job.core.lifecycle.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .animation(.default, value: job.core.lifecycle.status)
            .padding(.leading, SidebarLayout.disclosureGutterWidth)
        }
        .transaction(value: job.id) { transaction in
            transaction.disablesAnimations = true
        }
    }

    private var subtitleText: String? {
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

struct TimerLabelView: View {
    var job: CodexReviewJob

    var body: some View {
        if let startedAt = job.core.lifecycle.startedAt {
            Text(
                timerInterval: startedAt...(job.core.lifecycle.endedAt ?? .distantFuture),
                pauseTime: job.core.lifecycle.endedAt,
                countsDown: false,
                showsHours: true
            )
            .monospacedDigit()
        }
    }
    private func elapsedTimeText(startedAt: Date, referenceDate: Date) -> some View {
        let elapsedSeconds = max(0, referenceDate.timeIntervalSince(startedAt).rounded(.down))
        return Text(
            Duration.seconds(elapsedSeconds),
            format: .time(pattern: elapsedTimePattern(for: elapsedSeconds))
        )
        .monospacedDigit()
        .contentTransition(.numericText(value: elapsedSeconds))
        .animation(.default, value: elapsedSeconds)
    }

    private func elapsedTimePattern(for elapsedSeconds: TimeInterval) -> Duration.TimeFormatStyle.Pattern {
        elapsedSeconds >= 3600 ? .hourMinute : .minuteSecond
    }
}

extension ReviewJobState {
    var color: Color {
        switch self {
        case .queued: .gray
        case .running: .clear
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .yellow
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
                            ReviewMonitorJobRowView(job: job)
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
