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

    @Test func intentionalCancellationDuringPreparedCutoverDoesNotSurfaceAnError() async throws {
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

        await updateGate.open()
        let token = try await cutover.value
        await admittedWrite.value
        try store.settingsService.cancelRuntimeCutover(token: token)

        #expect(store.settingsService.runtimeCutoverStatus == .awaitingRecovery)
        #expect(store.settings.isLoading == false)
        #expect(store.settings.lastErrorMessage == nil)
        #expect(await backend.settingsSnapshot().model == "before-cutover")
    }

    @Test func intentionalCancellationPreservesAnUnrelatedSettingsError() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        await backend.failNextSettingsUpdate(message: "Existing settings failure.")
        await store.updateSettingsModel("rejected-model")
        #expect(store.settings.lastErrorMessage == "Existing settings failure.")

        let token = try await store.settingsService.beginRuntimeCutover()
        try store.settingsService.cancelRuntimeCutover(token: token)

        #expect(store.settings.isLoading == false)
        #expect(store.settings.lastErrorMessage == "Existing settings failure.")
    }

    @Test func canceledCutoverReplaysDeferredRawIntentsOnceAfterNextCommit() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let canceledToken = try await store.settingsService.beginRuntimeCutover()

        await store.updateSettingsModel("deferred-model")
        await store.refreshSettings()
        try store.settingsService.cancelRuntimeCutover(token: canceledToken)
        #expect(await backend.recordedCommands().isEmpty)

        let replacementToken = try await store.settingsService.beginRuntimeCutover()
        #expect(await backend.recordedCommands().isEmpty)
        try await store.settingsService.commitRuntimeSnapshot(
            token: replacementToken,
            snapshot: initial
        )

        let commands = await backend.recordedCommands()
        #expect(commands.filter(\.isSettingsWrite).count == 1)
        #expect(commands.filter(\.isSettingsRead).count == 1)
        #expect(await backend.settingsSnapshot().model == "deferred-model")
        #expect(store.settings.selectedModel == "deferred-model")
    }

    @Test func callerCancellationCannotCancelOwnedCommitReplay() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let token = try await store.settingsService.beginRuntimeCutover()
        await store.updateSettingsModel("deferred-model")

        let replayGate = AsyncGate()
        await backend.holdNextSettingsUpdateCheckingCancellationAfterGate(with: replayGate)
        let commit = Task { @MainActor in
            try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
        }
        await backend.waitForSettingsUpdate()

        let joinedCommit = Task { @MainActor in
            try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
        }
        await Task.yield()
        commit.cancel()

        await #expect(
            throws: CodexReviewSettingsService.RuntimeCutoverError.cutoverAlreadyInProgress
        ) {
            try await store.settingsService.beginRuntimeCutover()
        }
        #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.tokenAlreadyConsumed) {
            try store.settingsService.cancelRuntimeCutover(token: token)
        }
        #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.tokenAlreadyConsumed) {
            try store.settingsService.abortRuntimeCutover(token: token, message: "Superseded.")
        }
        await #expect(
            throws: CodexReviewSettingsService.RuntimeCutoverError.conflictingCommitSnapshot
        ) {
            try await store.settingsService.commitRuntimeSnapshot(
                token: token,
                snapshot: settingsSnapshot(model: "conflicting-model")
            )
        }

        await replayGate.open()
        try await commit.value
        try await joinedCommit.value

        #expect(store.settingsService.runtimeCutoverStatus == .active)
        #expect(await backend.settingsSnapshot().model == "deferred-model")
        #expect(store.settings.selectedModel == "deferred-model")
        #expect(store.settings.lastErrorMessage == nil)

        await backend.failNextSettingsUpdate(message: "Rejected after commit.")
        await store.updateSettingsModel("rejected-model")
        #expect(await backend.settingsSnapshot().model == "deferred-model")
        #expect(store.settings.selectedModel == "deferred-model")
        #expect(store.settings.lastErrorMessage == "Rejected after commit.")
    }

    @Test func queuedSubmissionCannotTakeCommitOwnedDrain() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let token = try await store.settingsService.beginRuntimeCutover()
        let replayGate = AsyncGate()
        await backend.holdNextSettingsUpdateCheckingCancellationAfterGate(with: replayGate)

        let submittedEdit = Task { @MainActor in
            await store.updateSettingsModel("deferred-model")
            await store.refreshSettings()
        }
        let releaseReplay = Task {
            await backend.waitForSettingsUpdate()
            submittedEdit.cancel()
            await replayGate.open()
        }

        try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
        await submittedEdit.value
        await releaseReplay.value

        #expect(store.settingsService.runtimeCutoverStatus == .active)
        #expect(await backend.settingsSnapshot().model == "deferred-model")
        #expect(store.settings.selectedModel == "deferred-model")
        #expect(store.settings.lastErrorMessage == nil)
        #expect(await backend.recordedCommands().filter(\.isSettingsWrite).count == 1)
        #expect(await backend.recordedCommands().filter(\.isSettingsRead).count == 1)
    }

    @Test func completedCommitCannotOverwriteSuccessorOperation() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let secondPublished = settingsSnapshot(model: "first-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let firstToken = try await store.settingsService.beginRuntimeCutover()
        await store.updateSettingsModel("first-model")
        let firstReplayGate = AsyncGate()
        await backend.holdNextSettingsUpdate(with: firstReplayGate)

        let firstCommit = Task { @MainActor in
            try await store.settingsService.commitRuntimeSnapshot(
                token: firstToken,
                snapshot: initial
            )
        }
        await backend.waitForSettingsUpdate()

        let successor = Task { @MainActor in
            try await waitForCutoverStatus(.active, service: store.settingsService)
            let token = try await store.settingsService.beginRuntimeCutover()
            await store.updateSettingsModel("second-model")
            let secondReplayGate = AsyncGate()
            await backend.holdNextSettingsUpdate(with: secondReplayGate)
            let commit = Task { @MainActor in
                try await store.settingsService.commitRuntimeSnapshot(
                    token: token,
                    snapshot: secondPublished
                )
            }
            await backend.waitForSettingsUpdate()
            let joinedCommit = Task { @MainActor in
                try await store.settingsService.commitRuntimeSnapshot(
                    token: token,
                    snapshot: secondPublished
                )
            }
            await Task.yield()
            await secondReplayGate.open()
            try await commit.value
            try await joinedCommit.value
        }

        await firstReplayGate.open()
        try await firstCommit.value
        try await successor.value

        #expect(store.settingsService.runtimeCutoverStatus == .active)
        #expect(await backend.settingsSnapshot().model == "second-model")
        #expect(store.settings.selectedModel == "second-model")
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func genuineCommitReplayFailureRequeuesAndReprojectsRawIntent() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let token = try await store.settingsService.beginRuntimeCutover()
        await store.updateSettingsModel("deferred-model")
        await backend.failNextSettingsUpdate(message: "Injected replay failure.")

        do {
            try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
            Issue.record("Expected the backend replay failure.")
        } catch {
            #expect(error.localizedDescription == "Injected replay failure.")
        }

        #expect(store.settingsService.runtimeCutoverStatus == .awaitingRecovery)
        #expect(await backend.settingsSnapshot().model == "initial-model")
        #expect(store.settings.selectedModel == "deferred-model")
        #expect(store.settings.lastErrorMessage == "Injected replay failure.")
        await #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.tokenAlreadyConsumed) {
            try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
        }

        let recoveryToken = try await store.settingsService.beginRuntimeCutover()
        try await store.settingsService.commitRuntimeSnapshot(
            token: recoveryToken,
            snapshot: initial
        )

        #expect(store.settingsService.runtimeCutoverStatus == .active)
        #expect(await backend.settingsSnapshot().model == "deferred-model")
        #expect(store.settings.selectedModel == "deferred-model")
        #expect(store.settings.lastErrorMessage == nil)
        #expect(await backend.recordedCommands().filter(\.isSettingsWrite).count == 2)
    }

    @Test func backendCommitCancellationRequeuesIntentForRecovery() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let token = try await store.settingsService.beginRuntimeCutover()
        await store.updateSettingsModel("deferred-model")
        await backend.cancelNextSettingsUpdate()

        await #expect(throws: CancellationError.self) {
            try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: initial)
        }
        #expect(store.settingsService.runtimeCutoverStatus == .awaitingRecovery)
        #expect(await backend.settingsSnapshot().model == "initial-model")
        #expect(store.settings.selectedModel == "deferred-model")
        #expect(store.settings.lastErrorMessage != nil)

        let recoveryToken = try await store.settingsService.beginRuntimeCutover()
        try await store.settingsService.commitRuntimeSnapshot(token: recoveryToken, snapshot: initial)
        #expect(await backend.settingsSnapshot().model == "deferred-model")
        #expect(store.settings.selectedModel == "deferred-model")
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func cancellationTokenMisuseIsTypedAndNeverMutatesState() async throws {
        let initial = settingsSnapshot(model: "initial-model")
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let otherStore = makeStore(
            initial: initial,
            backend: FakeCodexReviewBackend(settings: backendSnapshot(initial))
        )
        let token = try await store.settingsService.beginRuntimeCutover()
        let tokenCopy = token

        #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.foreignToken) {
            try otherStore.settingsService.cancelRuntimeCutover(token: token)
        }
        #expect(otherStore.settingsService.runtimeCutoverStatus == .active)

        try store.settingsService.cancelRuntimeCutover(token: tokenCopy)
        #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.tokenAlreadyConsumed) {
            try store.settingsService.cancelRuntimeCutover(token: token)
        }
        #expect(store.settingsService.runtimeCutoverStatus == .awaitingRecovery)

        let nextToken = try await store.settingsService.beginRuntimeCutover()
        #expect(throws: CodexReviewSettingsService.RuntimeCutoverError.staleToken) {
            try store.settingsService.cancelRuntimeCutover(token: tokenCopy)
        }
        #expect(store.settingsService.runtimeCutoverStatus == .awaitingCommit)
        #expect(await backend.recordedCommands().isEmpty)
        try store.settingsService.cancelRuntimeCutover(token: nextToken)
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

    @Test func deferredOverridesBeforeModelComposeAgainstFinalModel() async throws {
        try await expectDeferredSelection([
            .reasoningEffort(.high), .serviceTier(.fast), .model("final-model"),
        ])
    }

    @Test func deferredModelBeforeOverridesComposesIdentically() async throws {
        try await expectDeferredSelection([
            .model("final-model"), .reasoningEffort(.high), .serviceTier(.fast),
        ])
    }

    @Test func latestDeferredIntentWinsForEverySelectionDimension() async throws {
        try await expectDeferredSelection([
            .reasoningEffort(.low), .reasoningEffort(.high),
            .serviceTier(.flex), .serviceTier(.fast),
            .model("discarded-model"), .model("final-model"),
        ])
    }

    @Test func deferredOverridesSurviveFinalModelArrivingDuringReplay() async throws {
        let initial = settingsSnapshot(
            model: "intermediate-model",
            models: [
                model("intermediate-model", reasoning: [.high], tiers: [.fast]),
                model("final-model", reasoning: [.high], tiers: [.fast]),
            ]
        )
        let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
        let store = makeStore(initial: initial, backend: backend)
        let token = try await store.settingsService.beginRuntimeCutover()
        await store.updateSettingsReasoningEffort(.high)
        await store.updateSettingsServiceTier(.fast)

        let published = settingsSnapshot(
            model: "intermediate-model",
            reasoningEffort: .medium,
            serviceTier: .flex,
            models: [
                model("intermediate-model", reasoning: [.medium], tiers: []),
                model("final-model", reasoning: [.high], tiers: [.fast]),
            ]
        )
        await backend.setSettingsSnapshot(backendSnapshot(published))
        let replayGate = AsyncGate()
        await backend.holdNextSettingsUpdate(with: replayGate)
        let commit = Task { @MainActor in
            try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: published)
        }
        await backend.waitForSettingsUpdate()
        await store.updateSettingsModel("final-model")
        await replayGate.open()
        try await commit.value

        let persisted = await backend.settingsSnapshot()
        #expect(persisted.model == "final-model")
        #expect(persisted.reasoningEffort == "high")
        #expect(persisted.serviceTier == "fast")
        #expect(store.settings.selectedModel == "final-model")
        #expect(store.settings.selectedReasoningEffort == .high)
        #expect(store.settings.selectedServiceTier == .fast)
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

private enum DeferredSelectionEdit {
    case model(String)
    case reasoningEffort(CodexReviewSettings.ReasoningEffort?)
    case serviceTier(CodexReviewSettings.ServiceTier?)

    @MainActor
    func apply(to store: CodexReviewStore) async {
        switch self {
        case .model(let model):
            await store.updateSettingsModel(model)
        case .reasoningEffort(let reasoningEffort):
            await store.updateSettingsReasoningEffort(reasoningEffort)
        case .serviceTier(let serviceTier):
            await store.updateSettingsServiceTier(serviceTier)
        }
    }
}

@MainActor
private func expectDeferredSelection(_ edits: [DeferredSelectionEdit]) async throws {
    let initial = settingsSnapshot(
        model: "intermediate-model",
        models: [
            model("intermediate-model", reasoning: [.high], tiers: [.fast]),
            model("discarded-model", reasoning: [.low], tiers: [.flex]),
            model("final-model", reasoning: [.high], tiers: [.fast]),
        ]
    )
    let backend = FakeCodexReviewBackend(settings: backendSnapshot(initial))
    let store = makeStore(initial: initial, backend: backend)
    let token = try await store.settingsService.beginRuntimeCutover()
    for edit in edits {
        await edit.apply(to: store)
    }

    let published = settingsSnapshot(
        model: "intermediate-model",
        reasoningEffort: .medium,
        serviceTier: .flex,
        models: [
            model("intermediate-model", reasoning: [.medium], tiers: []),
            model("discarded-model", reasoning: [.low], tiers: [.flex]),
            model("final-model", reasoning: [.high], tiers: [.fast]),
        ]
    )
    await backend.setSettingsSnapshot(backendSnapshot(published))
    try await store.settingsService.commitRuntimeSnapshot(token: token, snapshot: published)

    let persisted = await backend.settingsSnapshot()
    #expect(persisted.model == "final-model")
    #expect(persisted.reasoningEffort == "high")
    #expect(persisted.serviceTier == "fast")
    #expect(store.settings.selectedModel == "final-model")
    #expect(store.settings.selectedReasoningEffort == .high)
    #expect(store.settings.selectedServiceTier == .fast)
    let commands = await backend.recordedCommands()
    #expect(commands.filter(\.isSettingsWrite).count == 1)
    guard case .applySettings(let change) = try #require(commands.last) else {
        Issue.record("Expected one composed settings write.")
        return
    }
    #expect(change.updatesModel)
    #expect(change.updatesReasoningEffort)
    #expect(change.updatesServiceTier)
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
