import SwiftUI
import CodexReviewKit

enum AccountUsageSummaryPresentation: Equatable {
    case loading
    case gauges
    case provider(title: String, systemImage: String)

    @MainActor
    init(account: CodexReviewAccount?) {
        guard let account else {
            self = .loading
            return
        }
        guard account.capabilities.supportsRateLimitRefresh == false else {
            self = account.rateLimits.isEmpty ? .loading : .gauges
            return
        }

        self = switch account.kind {
        case .chatGPT:
            .provider(title: "Using ChatGPT", systemImage: "person.crop.circle.fill")
        case .apiKey:
            .provider(title: "Using API Key", systemImage: "key.fill")
        case .amazonBedrock:
            .provider(title: "Using Amazon Bedrock", systemImage: "cloud.fill")
        }
    }

    var showsRateLimitControls: Bool {
        switch self {
        case .loading, .gauges:
            true
        case .provider:
            false
        }
    }
}

struct AccountUsageSummaryView: View {
    var account: CodexReviewAccount?

    private static let placeholderRateLimits: [CodexReviewAccount.RateLimitWindow] = [
        CodexReviewAccount.RateLimitWindow(
            windowDurationMinutes: 1,
            usedPercent: 0
        ),
        CodexReviewAccount.RateLimitWindow(
            windowDurationMinutes: 2,
            usedPercent: 0
        ),
    ]

    private var rateLimits: [CodexReviewAccount.RateLimitWindow] {
        account?.rateLimits ?? []
    }

    private var displayedRateLimits: [CodexReviewAccount.RateLimitWindow] {
        rateLimits.isEmpty ? Self.placeholderRateLimits : rateLimits
    }

    var body: some View {
        let presentation = AccountUsageSummaryPresentation(account: account)
        switch presentation {
        case .loading, .gauges:
            VStack(spacing:0) {
                ForEach(displayedRateLimits) { window in
                    RateLimitWindowGaugeView(window: window)
                        .transaction(value: account?.id) { transaction in
                            transaction.disablesAnimations = true
                        }
                }
            }
            .redacted(reason: presentation == .loading ? .placeholder : [])
            .animation(.easeInOut, value: presentation == .loading)
        case .provider(let title, let systemImage):
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct RateLimitWindowGaugeView: View {
    var window: CodexReviewAccount.RateLimitWindow

    var body: some View {
        let remainingPercent = window.remainingPercent

        Gauge(value: Double(remainingPercent), in: 0 ... 100) {
            HStack {
                Text(window.formattedDuration)
                Spacer(minLength: 0)
                if let resetDate = window.limitResetDate {
                    Text(resetDate, style: .offset)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        Double(remainingPercent) / 100,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .contentTransition(.numericText(value: Double(remainingPercent)))
                }
            }
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .animation(.default, value: remainingPercent)
    }
}

extension CodexReviewAccount.RateLimitWindow {
    var limitResetDate: Date? {
        guard usedPercent >= 100 else {
            return nil
        }
        return resetsAt
    }

    var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    var formattedDuration: String {
        Duration.seconds(windowDurationMinutes * 60).formatted(
            .units(
                allowed: [.minutes, .hours, .days, .weeks],
                width: .wide,
                maximumUnitCount: 2
            )
        )
    }
}

#if DEBUG
#Preview("Account Rate Limit Gauges") {
    AccountUsageSummaryView(account: makeAccountRateLimitGaugesPreviewAccount())
        .padding()
        .frame(width: 320)
}

#Preview("API Key Usage") {
    AccountUsageSummaryView(
        account: CodexReviewAccount(
            accountKey: "api-key",
            email: "API Key",
            kind: .apiKey
        )
    )
    .padding()
    .frame(width: 320)
}

@MainActor
private func makeAccountRateLimitGaugesPreviewAccount() -> CodexReviewAccount {
    let account = CodexReviewAccount(email: "review@example.com", planType: "pro")
    account.updateRateLimits(
        [
            (
                windowDurationMinutes: 300,
                usedPercent: 34,
                resetsAt: Date.now.addingTimeInterval(60 * 60)
            ),
            (
                windowDurationMinutes: 10_080,
                usedPercent: 61,
                resetsAt: Date.now.addingTimeInterval(24 * 60 * 60)
            ),
        ]
    )
    return account
}
#endif
