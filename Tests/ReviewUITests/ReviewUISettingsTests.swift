import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(PreviewSupport) @testable import ReviewUI
import CodexReviewTesting

@Suite(.serialized)
@MainActor
struct ReviewUISettingsTests {
    @Test func settingsSnapshotLoadsEffectiveSelections() {
        let settingsSnapshot = makeSettingsSnapshot(
            model: "gpt-5.4-mini",
            reasoningEffort: .low,
            serviceTier: nil
        )
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: settingsSnapshot)
        )
        store.loadForTesting(
            serverState: .running,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: [],
            settingsSnapshot: settingsSnapshot
        )

        #expect(store.settings.effectiveModel == "gpt-5.4-mini")
        #expect(store.settings.effectiveReasoningEffort == .low)
        #expect(store.settings.selectedServiceTier == nil)
    }

    @Test func statusViewDisablesSettingsControlsWhenServerIsNotRunning() {
        let settingsSnapshot = makeSettingsSnapshot()
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(initialSettingsSnapshot: settingsSnapshot)
        )
        store.loadForTesting(
            serverState: .stopped,
            authState: .signedIn(accountID: "review@example.com"),
            workspaces: [],
            settingsSnapshot: settingsSnapshot
        )

        #expect(store.serverState != .running || store.settings.isLoading || store.settings.displayedModels.isEmpty)
    }

    @Test func settingsStoreNormalizesReasoningAndTierWhenModelChanges() async {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(
                initialSettingsSnapshot: makeSettingsSnapshot(
                    model: "gpt-5.4",
                    reasoningEffort: .high,
                    serviceTier: .fast
                )
            )
        )

        await store.updateSettingsModel("gpt-5.4-mini")

        #expect(store.settings.selectedModel == "gpt-5.4-mini")
        #expect(store.settings.selectedReasoningEffort == nil)
        #expect(store.settings.selectedServiceTier == nil)
        #expect(store.settings.effectiveReasoningEffort == .medium)
    }

    @Test func settingsStoreKeepsCurrentHiddenModelVisible() {
        let hiddenModel = CodexReviewModelCatalogItem(
            id: "gpt-hidden",
            model: "gpt-hidden",
            displayName: "GPT Hidden",
            hidden: true,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Hidden default.")
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: []
        )
        let visibleModel = CodexReviewModelCatalogItem(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Visible default.")
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast]
        )
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(
                initialSettingsSnapshot: .init(
                    model: "gpt-hidden",
                    reasoningEffort: .medium,
                    serviceTier: nil,
                    models: [visibleModel, hiddenModel]
                )
            )
        )

        #expect(store.settings.displayedModels.map(\.model) == ["gpt-5.4", "gpt-hidden"])
    }

    @Test func settingsStoreKeepsConfiguredMissingModelVisible() {
        let visibleModel = CodexReviewModelCatalogItem(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Visible default.")
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast]
        )
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(
                initialSettingsSnapshot: .init(
                    model: "gpt-missing",
                    reasoningEffort: nil,
                    serviceTier: nil,
                    models: [visibleModel]
                )
            )
        )

        #expect(store.settings.displayedModels.map(\.model) == ["gpt-5.4", "gpt-missing"])
        #expect(store.settings.effectiveModel == "gpt-missing")
        #expect(store.settings.effectiveModelItem == nil)
    }

    @Test func settingsStorePreservesIncompatiblePersistedOverridesUntilEdited() {
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(
                initialSettingsSnapshot: makeSettingsSnapshot(
                    model: "gpt-5.4-mini",
                    reasoningEffort: .high,
                    serviceTier: .fast
                )
            )
        )

        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.selectedServiceTier == .fast)
        #expect(store.settings.effectiveReasoningEffort == .high)
    }

    @Test func settingsStorePreservesReasoningOverrideWhenModelCatalogOmitsOptions() {
        let modelWithoutReasoningOptions = CodexReviewModelCatalogItem(
            id: "gpt-no-options",
            model: "gpt-no-options",
            displayName: "GPT No Options",
            hidden: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: []
        )
        let store = CodexReviewStore.makePreviewStore(
            seed: .init(
                initialSettingsSnapshot: .init(
                    model: "gpt-no-options",
                    fallbackModel: nil,
                    reasoningEffort: .high,
                    serviceTier: nil,
                    models: [modelWithoutReasoningOptions]
                )
            )
        )

        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.effectiveReasoningEffort == .high)
    }

    @Test func modelCatalogItemDisplayNamesNormalizeAndCompactGPTNames() {
        let cases: [(displayName: String, normalized: String, compact: String)] = [
            ("gpt-5.4", "GPT-5.4", "5.4"),
            ("gpt-5.3-codex", "GPT-5.3-Codex", "5.3"),
            ("gpt-5.3-codex-spark", "GPT-5.3-Codex-Spark", "5.3 Spark"),
            ("GPT-5.3 Codex", "GPT-5.3 Codex", "5.3"),
            ("GPT-5.4-Mini", "GPT-5.4-Mini", "5.4 Mini"),
            ("gpt-5.2", "GPT-5.2", "5.2"),
            ("codex-auto-review", "codex-auto-review", "codex-auto-review"),
        ]

        for testCase in cases {
            let item = CodexReviewModelCatalogItem(
                id: testCase.displayName,
                model: testCase.displayName,
                displayName: testCase.displayName,
                hidden: false,
                supportedReasoningEfforts: [
                    .init(reasoningEffort: .medium, description: "Default.")
                ],
                defaultReasoningEffort: .medium,
                supportedServiceTiers: []
            )

            #expect(item.normalizedDisplayName == testCase.normalized)
            #expect(item.compactDisplayName == testCase.compact)
        }
    }

    @Test func settingsStoreAppliesPendingSelectionAfterInFlightSave() async throws {
        let backend = BlockingSettingsBackend(snapshot: makeSettingsSnapshot())
        backend.blockNextModelUpdate()
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let modelUpdateTask = Task { @MainActor in
            await store.updateSettingsModel("gpt-5.4-mini")
        }
        await backend.waitForBlockedModelUpdateToStart()

        await store.updateSettingsReasoningEffort(.low)
        await backend.resumeBlockedModelUpdate()
        await modelUpdateTask.value

        try await waitForCondition {
            backend.reasoningUpdateCalls == [.low]
        }

        #expect(store.settings.selectedModel == "gpt-5.4-mini")
        #expect(store.settings.selectedReasoningEffort == .low)
        #expect(backend.modelUpdateCalls.count == 1)
    }

    @Test func settingsStorePersistsRevertQueuedDuringInFlightSave() async throws {
        let backend = BlockingSettingsBackend(snapshot: makeSettingsSnapshot())
        backend.blockNextModelUpdate()
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let modelUpdateTask = Task { @MainActor in
            await store.updateSettingsModel("gpt-5.4-mini")
        }
        await backend.waitForBlockedModelUpdateToStart()

        await store.updateSettingsModel("gpt-5.4")
        await backend.resumeBlockedModelUpdate()
        await modelUpdateTask.value

        try await waitForCondition {
            backend.modelUpdateCalls.map(\.model) == ["gpt-5.4-mini", "gpt-5.4"]
        }

        #expect(store.settings.selectedModel == "gpt-5.4")
    }

    @Test func settingsStoreRunsQueuedRefreshAfterCurrentLoad() async throws {
        let backend = BlockingSettingsBackend(snapshot: makeSettingsSnapshot())
        backend.blockNextRefresh()
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let refreshTask = Task { @MainActor in
            await store.refreshSettings()
        }
        await backend.waitForBlockedRefreshToStart()

        await store.refreshSettings()
        await backend.resumeBlockedRefresh()
        await refreshTask.value

        try await waitForCondition {
            backend.refreshCallCount == 2
        }
    }

    @Test func settingsStorePersistsQueuedReasoningAndTierWithoutWritingModelOverride() async throws {
        let backend = BlockingSettingsBackend(
            snapshot: makeSettingsSnapshot(
                model: "gpt-5.3-codex",
                reasoningEffort: .low,
                serviceTier: .fast
            )
        )
        backend.blockNextReasoningUpdate()
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let reasoningUpdateTask = Task { @MainActor in
            await store.updateSettingsReasoningEffort(.medium)
        }
        await backend.waitForBlockedReasoningUpdateToStart()

        await store.updateSettingsReasoningEffort(.minimal)
        await store.updateSettingsServiceTier(.flex)
        await backend.resumeBlockedReasoningUpdate()
        await reasoningUpdateTask.value

        try await waitForCondition {
            backend.reasoningUpdateCalls == [.medium, .minimal]
                && backend.serviceTierUpdateCalls == [.flex]
        }

        #expect(backend.modelUpdateCalls.isEmpty)
        #expect(store.settings.selectedReasoningEffort == .minimal)
        #expect(store.settings.selectedServiceTier == .flex)
    }

    @Test func settingsStorePersistsBackToBackObservedSelectionChanges() async throws {
        let backend = BlockingSettingsBackend(
            snapshot: makeSettingsSnapshot(
                model: "gpt-5.3-codex",
                reasoningEffort: .low,
                serviceTier: .fast
            )
        )
        backend.blockNextReasoningUpdate()
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let reasoningUpdateTask = Task { @MainActor in
            await store.updateSettingsReasoningEffort(.medium)
        }
        await backend.waitForBlockedReasoningUpdateToStart()
        await store.updateSettingsServiceTier(.flex)
        await backend.resumeBlockedReasoningUpdate()
        await reasoningUpdateTask.value

        try await waitForCondition {
            backend.reasoningUpdateCalls == [.medium]
                && backend.serviceTierUpdateCalls == [.flex]
        }

        #expect(store.settings.selectedReasoningEffort == .medium)
        #expect(store.settings.selectedServiceTier == .flex)
    }

    @Test func settingsStoreClearsModelOverrideBackToFallbackModel() async throws {
        let backend = BlockingSettingsBackend(
            snapshot: makeSettingsSnapshot(
                model: "gpt-5.4-mini",
                fallbackModel: "gpt-5.4",
                reasoningEffort: .low,
                serviceTier: nil
            )
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        await store.clearSettingsModelOverride()

        try await waitForCondition {
            backend.modelUpdateCalls == [
                .init(model: nil, reasoningEffort: .low, serviceTier: nil)
            ]
        }

        #expect(store.settings.selectedModel == nil)
        #expect(store.settings.effectiveModel == "gpt-5.4")
        #expect(store.settings.effectiveModelItem?.model == "gpt-5.4")
    }

    @Test func settingsStoreClearsReasoningOverrideBackToModelDefault() async throws {
        let backend = BlockingSettingsBackend(
            snapshot: makeSettingsSnapshot(
                model: "gpt-5.4",
                reasoningEffort: .high,
                serviceTier: .fast
            )
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        await store.clearSettingsReasoningEffort()

        try await waitForCondition {
            backend.reasoningUpdateCalls == [nil]
        }

        #expect(store.settings.selectedReasoningEffort == nil)
        #expect(store.settings.effectiveReasoningEffort == .medium)
    }
}
