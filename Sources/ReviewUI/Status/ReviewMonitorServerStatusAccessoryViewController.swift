import AppKit
import SwiftUI
import CodexReview
import ObservationBridge

@MainActor
final class ReviewMonitorServerStatusAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private let observationScope = ObservationScope()
    private var shouldHideStatusAccessory = false

    init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)

        automaticallyAppliesContentInsets = true
        view = NSHostingView(rootView: StatusView(
            store: store,
            showSettings: showSettings
        ))
        bindObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func bindObservation() {
        observationScope.observe(uiState) { [weak self] event, uiState in
            let shouldHide = uiState.sidebarSelection == .account
            guard let self else {
                return
            }
            self.updateVisibility(shouldHide: shouldHide, animated: event.kind != .initial)
        }
    }

    private func updateVisibility(shouldHide: Bool, animated: Bool) {
        shouldHideStatusAccessory = shouldHide
        guard animated else {
            isHidden = shouldHide
            view.alphaValue = shouldHide ? 0 : 1
            return
        }

        if shouldHide {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.shouldHideStatusAccessory else {
                        return
                    }
                    self.isHidden = true
                }
            }
        } else {
            isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                view.animator().alphaValue = 1
            }
        }
    }
}

struct AccountRateLimitsSectionView: View {
    let account: CodexAccount?

    var body: some View {
        ForEach(rateLimits) { window in
            GroupBox{
                rateLimitsRow(window)
            }label:{
                Text(window.formattedDuration)
            }
        }
    }

    @ViewBuilder
    private func rateLimitsRow(
        _ window: CodexRateLimitWindow
    ) -> some View {
        if let details = Self.rateLimitDetailsText(for: window) {
            Button {
            } label: {
                Text(details)
            }
        }
    }

    private var rateLimits: [CodexRateLimitWindow] {
        account?.rateLimits ?? []
    }

    static func rateLimitDetailsText(
        for window: CodexRateLimitWindow
    ) -> AttributedString? {
        guard let resetsAt = window.resetsAt else {
            return nil
        }
        var details = AttributedString(resetsAt.formatted(.dateTime))
        details.append(AttributedString("\n"))
        details.append(Date.now.formatted(.offset(to: resetsAt, sign: .never)))
        return details
    }
}

struct StatusView: View {
    var store: CodexReviewStore
    var showSettings: (@MainActor () -> Void)? = nil
    @State private var isReviewSettingsPopoverPresented = false

    private var settings: SettingsStore {
        store.settings
    }

    var body: some View {
        let currentAccount = store.auth.selectedAccount
        VStack{
            Menu {
                Section(currentAccount?.email ?? "") {
                    AccountRateLimitsSectionView(account: currentAccount)
                }
                if let showSettings {
                    Section{
                        Button{
                            showSettings()
                        }label:{
                            Label("Settings",systemImage: "gear")
                        }
                    }
                }
                
                if showsServerRestartAction {
                    Divider()
                    Button("Reset Server", systemImage: "arrow.clockwise") {
                        Task {
                            await store.restart()
                        }
                    }
                }
            } label: {
                AccountRateLimitGaugesView(account: currentAccount)
                    .transition(.blurReplace)
                    .animation(.default, value: currentAccount)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            HStack {
                ZStack{
                    Button {
                        isReviewSettingsPopoverPresented.toggle()
                    } label: {
                        Label{
                            Text("\(settings.effectiveModelItem?.compactDisplayName ?? settings.effectiveModel ?? "Model")  \(settings.effectiveReasoningEffort?.displayText ?? "Reasoning")")

                        }icon:{
                            if settings.selectedServiceTier == .fast{
                                Image(systemName:"bolt.fill")
                            }
                        }
                    }
                }
                .background(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(.clear)
                        .frame(width: 100)
                        .popover(
                            isPresented: $isReviewSettingsPopoverPresented
                        ) {
                            ReviewSettingsPickerPopoverView(
                                store: store
                            )
                        }
                }
                Spacer(minLength: 0)
            }
            .disabled(
                store.serverState != .running
                    || settings.isLoading
                    || settings.displayedModels.isEmpty
            )
        }
        .padding(8)
    }

    private var showsServerRestartAction: Bool {
        switch store.serverState {
        case .failed, .stopped, .starting:
            true
        case .running:
            false
        }
    }
}

private struct ReviewSettingsPickerPopoverView: View {
    var store: CodexReviewStore

    private var settings: SettingsStore {
        store.settings
    }

    var body: some View {
        Form {
            Section{
                // Match Codex CLI/App by listing only concrete reasoning choices from the model catalog.
                Picker("Reasoning", selection: reasoningSelection) {
                    ForEach(settings.availableReasoningOptions) { item in
                        Text(item.reasoningEffort.displayText)
                            .tag(Optional(item.reasoningEffort))
                    }
                }
            }
            // Keep this aligned with Codex CLI/App behavior without inventing an inherited/default row.
            Picker("Model", selection: modelSelection) {
                ForEach(settings.displayedModels) { item in
                    Label{
                        Text(item.normalizedDisplayName)
                    }icon:{
                        if item.supportedServiceTiers.contains(.fast) {
                            Image(systemName:"bolt.fill")
                        }
                    }
                    .tag(Optional(item.model))
                }
            }
            Picker("Tier", selection: serviceTierSelection) {
                Text("Normal").tag(Optional<CodexReviewServiceTier>.none)
                ForEach(settings.availableServiceTiers, id: \.self) { item in
                    Text(item.displayText).tag(Optional(item))
                }
            }
        }
        .pickerStyle(.inline)
        .formStyle(.columns)
        .scenePadding()
    }
    private var modelSelection: Binding<String?> {
        Binding(
            get: { settings.selectedModel },
            set: { model in
                Task { @MainActor in
                    if let model {
                        await store.updateSettingsModel(model)
                    } else {
                        await store.clearSettingsModelOverride()
                    }
                }
            }
        )
    }
    private var serviceTierSelection: Binding<CodexReviewServiceTier?> {
        Binding(
            get: { settings.selectedServiceTier },
            set: { serviceTier in
                Task { @MainActor in
                    await store.updateSettingsServiceTier(serviceTier)
                }
            }
        )
    }

    private var reasoningSelection: Binding<CodexReviewReasoningEffort?> {
        Binding(
            get: { settings.selectedReasoningEffort },
            set: { reasoningEffort in
                Task { @MainActor in
                    if let reasoningEffort {
                        await store.updateSettingsReasoningEffort(reasoningEffort)
                    } else {
                        await store.clearSettingsReasoningEffort()
                    }
                }
            }
        )
    }
}

#if DEBUG

#Preview("Signed In") {
    let store = makeStatusPreviewStore()
    StatusView(store: store)
        .padding()
}

#Preview("Server Failed") {
    let store = makeStatusPreviewStore(
        serverState: .failed("The embedded server stopped responding.")
    )
    StatusView(store: store)
        .padding()
}

@MainActor
func makeStatusPreviewStore(
    authPhase: CodexReviewAuthModel.Phase = .signedOut,
    account: CodexAccount? = nil,
    serverState: CodexReviewServerState = .running
) -> CodexReviewStore {
    let store = ReviewMonitorPreviewContent.makeStore()
    let runningServerURL = store.serverURL
    let previewAccounts = ReviewMonitorPreviewContent.makePreviewAccounts()
    let resolvedAccount = account ?? previewAccounts.first
    store.auth.updatePhase(authPhase)
    store.auth.applyPersistedAccountStates(previewAccounts.map(savedAccountPayload(from:)))
    store.auth.selectPersistedAccount(resolvedAccount?.id)
    store.serverState = serverState
    store.serverURL = serverState == .running ? runningServerURL : nil
    return store
}
@MainActor
func makeStatusPreviewAccount() -> CodexAccount {
    ReviewMonitorPreviewContent.makePreviewAccount()
}
#endif
