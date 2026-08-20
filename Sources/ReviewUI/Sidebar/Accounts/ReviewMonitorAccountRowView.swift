import CodexReview
import SwiftUI

struct ReviewMonitorAccountRowView: View {
    let store: CodexReviewStore
    var account: CodexAccount?
    
    var body: some View {
        if let account {
            Label {
                GroupBox{
                    Menu {
                        AccountContextMenuView(
                            store: store,
                            account: account
                        )
                    } label: {
                        AccountRateLimitGaugesView(
                            account: account
                        )
                        .textScale(.secondary)
                        .padding(2)
                        .contentShape(.rect)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }label:{
                    Text(account.maskedEmail)
                }
            } icon: {
                let isSelected :Bool = store.auth.selectedAccount == account
                Button {
                    guard store.switchActionIsDisabled(for: account) == false else {
                        return
                    }
                    store.requestSwitchAccountFromUserAction(account)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.selection))
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))
                        .animation(.easeInOut(duration: 0.22), value: isSelected)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("review-monitor.account-row-switch-button")
            }
            .labelIconToTitleSpacing(0)
            .overlay {
                if account.isSwitching {
                    ProgressView()
                        .accessibilityIdentifier("review-monitor.account-row-switching")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: account.isSwitching)
            .transaction(value: account.id) { transaction in
                transaction.disablesAnimations = true
            }
        }
    }
}
