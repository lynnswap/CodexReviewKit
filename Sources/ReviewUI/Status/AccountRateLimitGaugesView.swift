import SwiftUI
import CodexReview

struct AccountRateLimitGaugesView: View {
    var account: CodexAccount?

    private static let placeholderRateLimits: [CodexAccount.RateLimitWindow] = [
        CodexAccount.RateLimitWindow(
            windowDurationMinutes: 1,
            usedPercent: 0
        ),
        CodexAccount.RateLimitWindow(
            windowDurationMinutes: 2,
            usedPercent: 0
        ),
    ]

    private var rateLimits: [CodexAccount.RateLimitWindow] {
        account?.rateLimits ?? []
    }

    private var displayedRateLimits: [CodexAccount.RateLimitWindow] {
        rateLimits.isEmpty ? Self.placeholderRateLimits : rateLimits
    }

    private var showsRedactedRateLimits: Bool {
        rateLimits.isEmpty
    }

    var body: some View {
        Group {
            VStack(spacing:0) {
                ForEach(displayedRateLimits) { window in
                    RateLimitWindowGaugeView(window: window)
                        .transaction(value: account?.id) { transaction in
                            transaction.disablesAnimations = true
                        }
                }
            }
            .redacted(reason: showsRedactedRateLimits ? .placeholder : [])
            .animation(.easeInOut, value: showsRedactedRateLimits)
        }
    }
}

private struct RateLimitWindowGaugeView: View {
    var window: CodexAccount.RateLimitWindow

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

extension CodexAccount.RateLimitWindow {
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
    AccountRateLimitGaugesView(account: makeAccountRateLimitGaugesPreviewAccount())
        .padding()
        .frame(width: 320)
}

@MainActor
private func makeAccountRateLimitGaugesPreviewAccount() -> CodexAccount {
    let account = CodexAccount(email: "review@example.com", planType: "pro")
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
