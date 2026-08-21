import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
import CodexReviewTesting
@Suite("settings runtime cutover", .serialized)
@MainActor
struct CodexReviewSettingsRuntimeCutoverTests {
    @Test func cutoverDrainsAdmittedWriteAndReplaysDeferredEditAndRefresh() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let updateGate = AsyncGate()
        await backend.holdNextSettingsUpdate(with: updateGate)

        let admittedWrite = Task { @MainActor in
            await store.updateSettingsModel("before-cutover")
        }
        await backend.waitForSettingsUpdate()
        let cutover = Task { @MainActor in
            try await store.settingsService.beginRuntimeCutover()
        }
        try await waitForCutoverStatus(.draining, service: store.settingsService)

        await store.updateSettingsModel("after-cutover")
        await store.refreshSettings()
        #expect(await backend.recordedCommands().filter(\.isSettingsWrite).count == 1)
        #expect(await backend.recordedCommands().filter(\.isSettingsRead).isEmpty)

        await updateGate.open()
        let token = try await cutover.value
        await admittedWrite.value
        #expect(await backend.settingsSnapshot().model == "before-cutover")

        try await store.settingsService.commitRuntimeSnapshot(
            token: token,
            snapshot: settingsSnapshot(model: "before-cutover")
        )

        let commands = await backend.recordedCommands()
        #expect(commands.filter(\.isSettingsWrite).count == 2)
        #expect(commands.filter(\.isSettingsRead).count == 1)
        #expect(await backend.settingsSnapshot().model == "after-cutover")
        #expect(store.settings.selectedModel == "after-cutover")
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func failedAdmittedWriteTerminatesBeforeSnapshotBecomesRollbackBaseline() async throws {
        let initial = settingsSnapshot(model: "runtime-model", reasoningEffort: .high, serviceTier: .fast)
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let updateGate = AsyncGate()
        await backend.holdNextSettingsUpdate(with: updateGate)
        await backend.failNextSettingsUpdate(message: "Injected settings failure.")

        let admittedWrite = Task { @MainActor in
            await store.updateSettingsModel("failed-before-cutover")
        }
        await backend.waitForSettingsUpdate()
        let cutover = Task { @MainActor in
            try await store.settingsService.beginRuntimeCutover()
        }
        try await waitForCutoverStatus(.draining, service: store.settingsService)
        await store.updateSettingsModel("retained-model")

        await updateGate.open()
        let token = try await cutover.value
        await admittedWrite.value
        try store.settingsService.abortRuntimeCutover(
            token: token,
            message: "Runtime preparation failed."
        )

        #expect(await backend.settingsSnapshot().model == "runtime-model")
        #expect(store.settings.selectedModel == "retained-model")
        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.selectedServiceTier == .fast)
        #expect(store.settings.lastErrorMessage == "Runtime preparation failed.")

        let recoveryToken = try await store.settingsService.beginRuntimeCutover()
        try await store.settingsService.commitRuntimeSnapshot(token: recoveryToken, snapshot: initial)
        #expect(await backend.settingsSnapshot().model == "retained-model")
        #expect(store.settings.selectedModel == "retained-model")
        #expect(store.settings.lastErrorMessage == nil)

        await backend.failNextSettingsUpdate(message: "Rejected after publication.")
        await store.updateSettingsModel("rejected-model")
        #expect(store.settings.selectedModel == "retained-model")
        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.selectedServiceTier == .fast)
        #expect(store.settings.lastErrorMessage == "Rejected after publication.")
    }

    @Test func deferredSelectionIsRenormalizedAndSerializedBeforeNewEdit() async throws {
        let initial = settingsSnapshot(
            model: "initial-model",
            models: [model("initial-model", reasoning: [.high], tiers: [.fast])]
        )
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let token = try await store.settingsService.beginRuntimeCutover()

        await store.updateSettingsReasoningEffort(.high)
        await store.updateSettingsServiceTier(.fast)
        #expect(await backend.recordedCommands().filter(\.isSettingsWrite).isEmpty)
        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.selectedServiceTier == .fast)

        let published = settingsSnapshot(
            model: "initial-model",
            reasoningEffort: .medium,
            serviceTier: .flex,
            models: [
                model("initial-model", reasoning: [.medium], tiers: []),
                model("next-model", reasoning: [.medium], tiers: []),
            ]
        )
        await backend.setSettingsSnapshot(backendSnapshot(published))
        let replayGate = AsyncGate()
        await backend.holdNextSettingsUpdate(with: replayGate)
        let commit = Task { @MainActor in
            try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: published)
        }
        await backend.waitForSettingsUpdate()
        await store.updateSettingsModel("next-model")
        await replayGate.open()
        try await commit.value

        let persisted = await backend.settingsSnapshot()
        #expect(persisted.model == "next-model")
        #expect(persisted.reasoningEffort == nil)
        #expect(persisted.serviceTier == nil)
        #expect(store.settings.selectedModel == "next-model")
        #expect(store.settings.selectedReasoningEffort == nil)
        #expect(store.settings.selectedServiceTier == nil)
        #expect(await backend.recordedCommands().filter(\.isSettingsWrite).count == 3)
    }

    @Test func tokenMisuseNeverMutatesState() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let otherStore = makeStore(
            initial: initial,
            backend: FakeCodexReviewBackend(settings: backendSnapshot(initial))
        )
        let token = try await store.settingsService.beginRuntimeCutover()
        let tokenCopy = token

        await #expect(
            throws: CodexReviewSettingsService.RuntimeCutoverError.cutoverAlreadyInProgress
        ) {
            try await store.settingsService.beginRuntimeCutover()
        }
        await #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.foreignToken) {
            try await otherStore.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
        }

        try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
        await #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.tokenAlreadyConsumed) {
            try await store.settingsService.commitRuntimeSnapshot(token: tokenCopy, snapshot: initial)
        }

        let nextToken = try await store.settingsService.beginRuntimeCutover()
        try await store.settingsService.commitRuntimeSnapshot(token: nextToken, snapshot: initial)
        await #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.staleToken) {
            try await store.settingsService.commitRuntimeSnapshot(token: tokenCopy, snapshot: initial)
        }
        await #expect(
            throws: CodexReviewSettingsService.RuntimeCutoverError.tokenAlreadyConsumed
        ) {
            try await store.settingsService.commitRuntimeSnapshot(
                token: nextToken,
                snapshot: initial
            )
        }
    }
}
private extension FakeCodexReviewBackend.Command {
    var isSettingsRead: Bool {
        if case .readSettings = self { true } else { false }
    }

    var isSettingsWrite: Bool {
        if case .applySettings = self { true } else { false }
    }
}

@MainActor
private func makeStore(
    initial: CodexReviewSettings.Snapshot,
    backend: FakeCodexReviewBackend
) -> CodexReviewStore {
    CodexReviewStore.makeTestingStore(
        backend: TestingCodexReviewStoreBackend(
            reviewBackend: backend,
            seed: .init(initialSettingsSnapshot: initial)
        )
    )
}

@MainActor
private func waitForCutoverStatus(
    _ expected: CodexReviewSettingsService.RuntimeCutoverStatus,
    service: CodexReviewSettingsService
) async throws {
    for _ in 0..<1_000 {
        if service.runtimeCutoverStatus == expected {
            return
        }
        await Task.yield()
    }
    Issue.record("Settings runtime cutover did not reach \(expected).")
}

private func backendSnapshot(
    _ snapshot: CodexReviewSettings.Snapshot
) -> CodexReviewBackendModel.Settings.Snapshot {
    .init(
        model: snapshot.model,
        fallbackModel: snapshot.fallbackModel,
        reasoningEffort: snapshot.reasoningEffort?.rawValue,
        serviceTier: snapshot.serviceTier?.rawValue,
        models: snapshot.models
    )
}

private func settingsSnapshot(
    model: String?,
    reasoningEffort: CodexReviewSettings.ReasoningEffort? = nil,
    serviceTier: CodexReviewSettings.ServiceTier? = nil,
    models: [CodexReviewSettings.ModelCatalogItem] = []
) -> CodexReviewSettings.Snapshot {
    .init(
        model: model,
        reasoningEffort: reasoningEffort,
        serviceTier: serviceTier,
        models: models
    )
}

private func model(
    _ name: String,
    reasoning: [CodexReviewSettings.ReasoningEffort],
    tiers: [CodexReviewSettings.ServiceTier]
) -> CodexReviewSettings.ModelCatalogItem {
    .init(
        id: name,
        model: name,
        displayName: name,
        hidden: false,
        supportedReasoningEfforts: reasoning.map {
            .init(reasoningEffort: $0, description: $0.rawValue)
        },
        defaultReasoningEffort: reasoning.first ?? .medium,
        supportedServiceTiers: tiers
    )
}
