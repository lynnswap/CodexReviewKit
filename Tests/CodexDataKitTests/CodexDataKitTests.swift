import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Observation
import Synchronization
import Testing

private func requireEquatable<T: Equatable>(_: T.Type) {}
private func requireSendable<T: Sendable>(_: T.Type) {}
private func requireSendableMetatype<T: SendableMetatype>(_: T.Type) {}
private func requireSerialExecutor<T: SerialExecutor>(_: T.Type) {}

@MainActor
private func expectModelIsDetached(
    _ operation: @MainActor () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected modelIsDetached")
    } catch let error as CodexModelContextError {
        #expect(error == .modelIsDetached)
    } catch {
        Issue.record("Expected modelIsDetached, got \(error)")
    }
}

private func testWorkspaceID(for url: URL) -> CodexWorkspaceID {
    CodexWorkspaceID(rawValue: url.standardizedFileURL.resolvingSymlinksInPath().path)
}

private func archivedChatPredicate(_ archived: Bool) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == archived
    }
}

private func archivedNotEqualChatPredicate(_ archived: Bool) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived != archived
    }
}

private func searchChatPredicate(_ searchTerm: String) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.searchableText.localizedStandardContains(searchTerm)
    }
}

private func modelProviderChatPredicate(_ modelProviders: [String]) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.modelProvider != nil
            && modelProviders.contains(chat.modelProvider!)
    }
}

private func providerSearchDisjunctionChatPredicate(
    firstProvider: String,
    secondProvider: String,
    searchTerm: String
) -> Predicate<CodexChat> {
    let first: String? = firstProvider
    let second: String? = secondProvider
    return #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && ((chat.modelProvider == first
                && chat.searchableText.localizedStandardContains(searchTerm))
            || (chat.modelProvider == second && chat.searchableText.localizedStandardContains(searchTerm))
            )
    }
}

private func nonNilModelProviderChatPredicate() -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == false && chat.modelProvider != nil
    }
}

private func nilSourceKindChatPredicate() -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == false && chat.sourceKind == nil
    }
}

private func nonNilSourceKindChatPredicate() -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == false && chat.sourceKind != nil
    }
}

private func archivedNilModelProviderChatPredicate() -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived && chat.modelProvider == nil
    }
}

private func negatedActiveProviderChatPredicate(_ modelProvider: String) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        !(chat.isArchived == false && chat.modelProvider == modelProvider)
    }
}

private func archivedDoubleSearchChatPredicate(
    archived: Bool,
    first: String,
    second: String
) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == archived
            && chat.searchableText.localizedStandardContains(first)
            && chat.searchableText.localizedStandardContains(second)
    }
}

private func constantChatPredicate(_ value: Bool) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { _ in
        value
    }
}

private func sourceKindChatPredicate(_ sourceKinds: [CodexThreadSourceKind]) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.sourceKind != nil
            && sourceKinds.contains(chat.sourceKind!)
    }
}

private func sourceKindEqualityChatPredicate(
    _ sourceKind: CodexThreadSourceKind
) -> Predicate<CodexChat> {
    let optionalSourceKind: CodexThreadSourceKind? = sourceKind
    return #Predicate<CodexChat> { chat in
        chat.isArchived == false && chat.sourceKind == optionalSourceKind
    }
}

private func sourceKindSearchChatPredicate(
    _ sourceKind: CodexThreadSourceKind,
    searchTerm: String
) -> Predicate<CodexChat> {
    let optionalSourceKind: CodexThreadSourceKind? = sourceKind
    return #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.sourceKind == optionalSourceKind
            && chat.searchableText.localizedStandardContains(searchTerm)
    }
}

private func workspaceChatPredicate(_ workspace: URL) -> Predicate<CodexChat> {
    let workspaceID: CodexWorkspaceID? = testWorkspaceID(for: workspace)
    return #Predicate<CodexChat> { chat in
        chat.isArchived == false && chat.workspaceID == workspaceID
    }
}

private func workspaceChatPredicate(_ workspaces: [URL]) -> Predicate<CodexChat> {
    let workspaceIDs = workspaces.map(testWorkspaceID(for:))
    return #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.workspaceID != nil
            && workspaceIDs.contains(chat.workspaceID!)
    }
}

private func nonOptionalFieldEqualityChatPredicate(
    workspace: URL,
    modelProvider: String,
    sourceKind: CodexThreadSourceKind
) -> Predicate<CodexChat> {
    let workspaceID = testWorkspaceID(for: workspace)
    return #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.workspaceID == workspaceID
            && chat.modelProvider == modelProvider
            && chat.sourceKind == sourceKind
    }
}

private func archivedSourceKindChatPredicate(
    archived: Bool,
    sourceKinds: [CodexThreadSourceKind]
) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == archived
            && chat.sourceKind != nil
            && sourceKinds.contains(chat.sourceKind!)
    }
}

private func workspaceSourceKindChatPredicate(
    workspace: URL,
    sourceKinds: [CodexThreadSourceKind]
) -> Predicate<CodexChat> {
    let workspaceID: CodexWorkspaceID? = testWorkspaceID(for: workspace)
    return #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.workspaceID == workspaceID
            && chat.sourceKind != nil
            && sourceKinds.contains(chat.sourceKind!)
    }
}

private func fullThreadListChatPredicate(
    archived: Bool,
    workspace: URL,
    searchTerm: String,
    modelProviders: [String],
    sourceKinds: [CodexThreadSourceKind]
) -> Predicate<CodexChat> {
    let workspaceID: CodexWorkspaceID? = testWorkspaceID(for: workspace)
    let modelProvider: String? = modelProviders.first
    let firstSourceKind: CodexThreadSourceKind? = sourceKinds.first
    let secondSourceKind: CodexThreadSourceKind? = sourceKinds.dropFirst().first
    return #Predicate<CodexChat> { chat in
        chat.isArchived == archived
            && chat.workspaceID == workspaceID
            && chat.searchableText.localizedStandardContains(searchTerm)
            && chat.modelProvider == modelProvider
            && (chat.sourceKind == firstSourceKind || chat.sourceKind == secondSourceKind)
    }
}

private extension CodexThreadSnapshot {
    func withSourceKind(_ sourceKind: CodexThreadSourceKind) -> CodexThreadSnapshot {
        CodexThreadSnapshot(
            id: id,
            workspace: workspace,
            name: name,
            preview: preview,
            modelProvider: modelProvider,
            sessionID: sessionID,
            parentThreadID: parentThreadID,
            source: source,
            sourceKind: sourceKind,
            gitInfo: gitInfo,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            status: status,
            ephemeral: ephemeral,
            turns: turns
        )
    }
}

private actor TestCodexModelActor: CodexModelActor {
    nonisolated let modelContainer: CodexModelContainer
    nonisolated let modelExecutor: CodexDefaultSerialModelExecutor

    private var chatObservation: CodexChatObservation?

    init(modelContainer: CodexModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = CodexDefaultSerialModelExecutor(modelContainer: modelContainer)
    }

    func fetchRecentChatIDs() async throws -> [CodexThreadID] {
        try await modelContext.fetch(CodexFetchDescriptor<CodexChat>.recentChats)
            .map(\.id)
    }

    func startReviewID(in workspace: URL, input: CodexReviewInput) async throws -> CodexThreadID {
        let started = try await modelContext.startReview(in: workspace, input: input)
        return started.chat.id
    }

    func observeChat(_ chatID: CodexThreadID) async throws {
        let chat = modelContext.model(for: chatID)
        chatObservation = try await chat.observe()
        withObservationTracking {
            _ = chat.turns
        } onChange: { [weak self] in
            guard let self else { return }
            self.preconditionIsolated(
                "Observed chat mutations must run on the context owner's executor."
            )
        }
    }

    func observedItemTexts(_ chatID: CodexThreadID) -> [String] {
        modelContext.model(for: chatID).items.compactMap(\.text)
    }

    func cancelChatObservation() {
        chatObservation?.cancel()
        chatObservation = nil
    }

    func observationReleaseSignalForTesting() -> ChatObservationReleaseSignal? {
        chatObservation?.releaseSignalForTesting
    }
}

@MainActor
struct CodexModelContextTests {
    @Test("model containers and contexts use instance identity equality")
    func modelContainerAndContextEqualityUsesInstanceIdentity() async throws {
        requireEquatable(CodexModelContainer.self)
        requireSendable(CodexModelContainer.self)
        requireSendableMetatype(CodexModelContainer.self)
        requireEquatable(CodexModelContext.self)
        requireSendableMetatype(CodexModelContext.self)
        requireSerialExecutor(CodexDefaultSerialModelExecutor.self)

        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let otherContainer = CodexModelContainer(appServer: runtime.server)

        #expect(container == container)
        #expect(container != otherContainer)
        #expect(container.mainContext == container.mainContext)
        #expect(container.mainContext != CodexModelContext(container))
    }

    @Test("container releases its main context without a retain cycle")
    func containerReleasesMainContextWithoutRetainCycle() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        weak var weakContainer: CodexModelContainer?

        do {
            let container = CodexModelContainer(appServer: runtime.server)
            weakContainer = container
            _ = container.mainContext
        }

        #expect(weakContainer == nil)
    }

    @Test("container releases loaded workspace graphs without retain cycles")
    func containerReleasesLoadedWorkspaceGraphsWithoutRetainCycles() async throws {
        weak var weakContainer: CodexModelContainer?
        weak var weakContext: CodexModelContext?
        weak var weakGroup: CodexWorkspaceGroup?
        weak var weakWorkspace: CodexWorkspace?
        weak var weakChat: CodexChat?

        do {
            let runtime = try await CodexAppServerTestRuntime.start()
            let container = CodexModelContainer(appServer: runtime.server)
            let context = container.mainContext
            weakContainer = container
            weakContext = context

            try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
                .init(id: "thread-release", workspace: temporaryDirectory(), name: "Release")
            ]))
            let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
            try await results.performFetch()
            let chat = try #require(results.items.first)
            weakChat = chat
            weakWorkspace = chat.workspace
            weakGroup = chat.workspace?.workspaceGroup

            #expect(weakGroup != nil)
            #expect(weakWorkspace != nil)
            #expect(weakChat != nil)
        }

        #expect(weakContainer == nil)
        #expect(weakContext == nil)
        #expect(weakGroup == nil)
        #expect(weakWorkspace == nil)
        #expect(weakChat == nil)
    }

    @Test("model actor creates its own context from a container")
    func modelActorCreatesOwnContextFromContainer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let modelActor = TestCodexModelActor(modelContainer: container)
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "model-actor-chat", workspace: temporaryDirectory(), name: "Model Actor")
        ]))

        let chatIDs = try await modelActor.fetchRecentChatIDs()

        #expect(chatIDs == [CodexThreadID("model-actor-chat")])
        #expect(container.mainContext.registeredModel(for: CodexThreadID("model-actor-chat")) == nil)
    }

    @Test("model actor observations apply live events on the actor context")
    func modelActorObservationAppliesLiveEvents() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let modelActor = TestCodexModelActor(modelContainer: container)
        let chatID = CodexThreadID("thread-actor-live")

        try await runtime.transport.enqueueThreadResume(.init(id: chatID))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: []))
        try await runtime.transport.enqueueThreadRead(.init(
            id: chatID,
            workspace: temporaryDirectory(),
            name: "Actor Live"
        ))

        try await modelActor.observeChat(chatID)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-actor-live",
                turnID: "turn-actor-live"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                lifecycle: .completed,
                threadID: "thread-actor-live",
                turnID: "turn-actor-live",
                item: .init(
                    id: "message-actor-live",
                    type: "agentMessage",
                    text: "Live",
                    phase: "final_answer"
                )
            )
        )

        #expect(await eventually {
            await modelActor.observedItemTexts(chatID).contains("Live")
        })
        #expect(container.mainContext.registeredModel(for: chatID) == nil)
        await modelActor.cancelChatObservation()
    }

    @Test("an active observation lease does not retain its model actor")
    func activeObservationLeaseDoesNotRetainModelActor() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let chatID = CodexThreadID("thread-actor-release")
        weak var weakModelActor: TestCodexModelActor?
        var releaseSignal: ChatObservationReleaseSignal?

        try await runtime.transport.enqueueThreadResume(.init(id: chatID))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: []))
        try await runtime.transport.enqueueThreadRead(.init(
            id: chatID,
            workspace: temporaryDirectory(),
            name: "Actor Release"
        ))

        do {
            let modelActor = TestCodexModelActor(modelContainer: container)
            weakModelActor = modelActor
            try await modelActor.observeChat(chatID)
            releaseSignal = await modelActor.observationReleaseSignalForTesting()
            #expect(releaseSignal?.releasedLeaseCountForTesting() == 0)
        }

        #expect(await eventually { weakModelActor == nil })
        let signal = try #require(releaseSignal)
        #expect(await eventually {
            signal.releasedLeaseCountForTesting() == 1
                && signal.receiverDidCompleteForTesting()
        })
    }

    @Test("an observation handle retains its context until the handle is released")
    func observationHandleRetainsContextOwner() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let chatID = CodexThreadID("thread-observation-context-owner")
        weak var weakContext: CodexModelContext?
        var observation: CodexChatObservation?

        try await runtime.transport.enqueueThreadResume(.init(id: chatID))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: []))
        try await runtime.transport.enqueueThreadRead(.init(id: chatID, turns: []))

        do {
            let container = CodexModelContainer(appServer: runtime.server)
            let context = container.mainContext
            weakContext = context
            observation = try await context.model(for: chatID).observe()
        }

        #expect(weakContext != nil)
        await observation?.close()
        observation = nil
        #expect(await eventually { weakContext == nil })
    }

    @Test("model actor review starts multicast to the eager main context")
    func modelActorReviewStartsMulticastToEagerMainContext() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let modelActor = TestCodexModelActor(modelContainer: container)

        try await runtime.transport.enqueueThreadStart(
            threadID: "thread-early-review",
            model: "gpt-5"
        )
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-early-review",
            reviewThreadID: "thread-early-review"
        )

        let reviewChatID = try await modelActor.startReviewID(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )

        let mainContext = container.mainContext
        let mainChat = try #require(mainContext.registeredModel(for: reviewChatID))
        #expect(mainChat.workspace?.url.path == workspaceURL.path)
    }

    @Test("foreign models fail every context-owned operation before app-server I/O")
    func foreignModelsFailContextOperationsBeforeAppServerIO() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let owningContext = CodexModelContainer(appServer: runtime.server).mainContext
        let foreignContext = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-foreign", workspace: workspaceURL, name: "Foreign")
        ]))
        let results = owningContext.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats
        )
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)
        let group = try #require(workspace.workspaceGroup)

        await expectModelIsDetached { try await foreignContext.refresh(group) }
        await expectModelIsDetached { try await foreignContext.refresh(workspace) }
        await expectModelIsDetached { try await foreignContext.refresh(chat) }
        await expectModelIsDetached { _ = try await foreignContext.observe(chat) }
        await expectModelIsDetached { _ = try await foreignContext.startChat(in: workspace) }
        await expectModelIsDetached {
            _ = try await foreignContext.startReview(
                in: workspace,
                input: .init(target: .uncommittedChanges)
            )
        }
        await expectModelIsDetached {
            _ = try await foreignContext.send(.init("hello"), in: chat)
        }
        await expectModelIsDetached { try await foreignContext.cancelActiveTurn(in: chat) }
        await expectModelIsDetached { try await foreignContext.archive(chat) }
        await expectModelIsDetached { try await foreignContext.unarchive(chat) }
        await expectModelIsDetached { try await foreignContext.delete(chat) }

        for method in [
            "thread/resume",
            "thread/start",
            "review/start",
            "turn/start",
            "turn/interrupt",
            "thread/archive",
            "thread/unarchive",
            "thread/delete",
        ] {
            #expect(await runtime.transport.recordedRequests(method: method).isEmpty)
        }
    }

    @Test("parent model refreshes throw after detaching from context")
    func parentModelRefreshesThrowAfterDetachingFromContext() async throws {
        var detachedWorkspace: CodexWorkspace?
        var detachedGroup: CodexWorkspaceGroup?
        weak var weakContext: CodexModelContext?

        do {
            let runtime = try await CodexAppServerTestRuntime.start()
            let container = CodexModelContainer(appServer: runtime.server)
            let context = container.mainContext
            weakContext = context
            let workspaceURL = temporaryDirectory()

            try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
                .init(id: "thread-detach", workspace: workspaceURL, name: "Detach")
            ]))
            let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
            try await results.performFetch()
            let chat = try #require(results.items.first)
            guard let workspace = chat.workspace,
                let group = workspace.workspaceGroup
            else {
                Issue.record("Expected fetched chat to have a workspace and group")
                return
            }
            detachedWorkspace = workspace
            detachedGroup = group
        }

        let workspace = try #require(detachedWorkspace)
        let group = try #require(detachedGroup)
        #expect(weakContext == nil)
        #expect(workspace.modelContext == nil)
        #expect(group.modelContext == nil)

        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        do {
            try await context.refresh(workspace)
            Issue.record("Expected detached workspace refresh to throw")
        } catch let error as CodexModelContextError {
            #expect(error == .modelIsDetached)
        } catch {
            Issue.record("Expected modelIsDetached for workspace refresh, got \(error)")
        }

        do {
            try await context.refresh(group)
            Issue.record("Expected detached group refresh to throw")
        } catch let error as CodexModelContextError {
            #expect(error == .modelIsDetached)
        } catch {
            Issue.record("Expected modelIsDetached for group refresh, got \(error)")
        }
    }

    @Test("fetched results use thread/list and mutate existing chat objects")
    func fetchedResultsMutateExistingChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)

        try await runtime.transport.enqueueThreadList(
            .init(profile: .partialDTO,
                threads: [
                    .init(
                        id: "thread-1",
                        name: "First",
                        modelProvider: "openai",
                        sourceKind: .cli,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        turns: [.init(id: "turn-1", state: .inProgress)]
                    )
                ],
                nextCursor: "next"
            ))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\CodexChat.recencyAt, order: .reverse)]
        ))
        try await results.performFetch()

        let first = try #require(results.items.first)
        let firstTurn = try #require(first.turns.first)
        #expect(first.title == "First")
        #expect(first.modelProvider == "openai")
        #expect(first.createdAt == createdAt)
        #expect(first.updatedAt == updatedAt)
        #expect(firstTurn.status == CodexTurnStatus.inProgress)
        #expect(first.modelContext === context)
        #expect(results.nextCursor == "next")

        try await runtime.transport.enqueueThreadList(
            .init(profile: .partialDTO, threads: [
                .init(
                    id: "thread-1",
                    name: "First renamed",
                    modelProvider: "openai",
                    sourceKind: .cli,
                    createdAt: createdAt,
                    updatedAt: Date(timeIntervalSince1970: 3_000),
                    turns: [.init(id: "turn-1", state: .completed)]
                ),
                .init(id: "thread-2", name: "Second", sourceKind: .cli),
            ]))

        try await results.performFetch()

        #expect(results.items.count == 2)
        #expect(context.model(for: CodexThreadID(rawValue: "thread-1")) === first)
        #expect(results.items.contains { $0 === first })
        #expect(first.title == "First renamed")
        #expect(first.turns.first === firstTurn)
        #expect(firstTurn.status == CodexTurnStatus.completed)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("thread provenance mutates in place, preserves omissions, and clears explicit nulls")
    func threadProvenanceUsesSnapshotPresenceSemantics() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chatID = CodexThreadID("thread-provenance")
        let parentThreadID = CodexThreadID("thread-parent")
        let source = CodexThreadSessionSource.subAgent(.threadSpawn(.init(
            parentThreadID: parentThreadID,
            depth: 2,
            agentPath: "research/metadata",
            agentNickname: "Ada",
            agentRole: "explorer"
        )))
        let gitInfo = CodexThreadGitInfo(
            sha: "0123456789abcdef",
            branch: "feature/provenance",
            originURL: "git@github.com:lynnswap/CodexKit.git"
        )
        let chat = context.model(for: chatID)

        chat.apply(
            .init(
                id: chatID,
                sessionID: "session-provenance",
                parentThreadID: parentThreadID,
                source: source,
                gitInfo: gitInfo
            ),
            workspace: nil
        )

        #expect(chat.sessionID == "session-provenance")
        #expect(chat.parentThreadID == parentThreadID)
        #expect(chat.source == source)
        #expect(chat.sourceKind == .subAgentThreadSpawn)
        #expect(chat.gitInfo == gitInfo)

        chat.apply(.init(id: chatID), workspace: nil)

        #expect(context.model(for: chatID) === chat)
        #expect(chat.sessionID == "session-provenance")
        #expect(chat.parentThreadID == parentThreadID)
        #expect(chat.source == source)
        #expect(chat.sourceKind == .subAgentThreadSpawn)
        #expect(chat.gitInfo == gitInfo)
        #expect(chat.observationSnapshot().sessionID == "session-provenance")
        #expect(chat.observationSnapshot().source == source)
        #expect(chat.observationSnapshot().gitInfo == gitInfo)

        chat.apply(
            .init(
                id: chatID,
                turnItemsAreAuthoritative: false,
                presentFields: [.sessionID, .parentThreadID, .source, .gitInfo]
            ),
            workspace: nil
        )

        #expect(context.model(for: chatID) === chat)
        #expect(chat.sessionID == nil)
        #expect(chat.parentThreadID == nil)
        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)
        #expect(chat.gitInfo == nil)
    }

    @Test("legacy source-kind snapshots preserve matching exact source metadata")
    func legacySourceKindSnapshotsStaySynchronizedWithExactSource() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID("thread-source-compatibility"))
        let exactSource = CodexThreadSessionSource.subAgent(.threadSpawn(.init(
            parentThreadID: "thread-parent",
            depth: 1,
            agentPath: nil,
            agentNickname: nil,
            agentRole: nil
        )))

        chat.apply(.init(id: chat.id, source: exactSource), workspace: nil)
        chat.apply(.init(id: chat.id, sourceKind: .subAgentThreadSpawn), workspace: nil)

        #expect(chat.source == exactSource)
        #expect(chat.sourceKind == .subAgentThreadSpawn)

        chat.apply(.init(id: chat.id, sourceKind: .appServer), workspace: nil)

        #expect(chat.source == nil)
        #expect(chat.sourceKind == .appServer)

        chat.apply(
            .init(
                id: chat.id,
                turnItemsAreAuthoritative: false,
                presentFields: [.sourceKind]
            ),
            workspace: nil
        )

        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)
    }

    @Test("exact provenance-only list changes revalidate registered fetched results")
    func exactProvenanceChangesRevalidateFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [{
                "id": "thread-provenance-revalidation",
                "sessionId": "session-provenance-revalidation",
                "parentThreadId": "thread-parent-revalidation",
                "source": {"custom": "atlas"},
                "gitInfo": {
                  "sha": "1111111111111111",
                  "branch": "feature/first",
                  "originUrl": "git@github.com:lynnswap/CodexKit.git"
                }
              }],
              "nextCursor": null
            }
            """
        )
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        let recorder = FetchedResultsTransactionRecorder(stream: results.transactions)
        try await results.performFetch()
        #expect(await eventually { recorder.transactions.count == 1 })
        let chat = try #require(results.items.first)
        #expect(chat.sessionID == "session-provenance-revalidation")
        #expect(chat.parentThreadID == "thread-parent-revalidation")
        #expect(chat.source == .custom("atlas"))
        #expect(chat.sourceKind == nil)
        #expect(chat.gitInfo?.branch == "feature/first")

        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [{
                "id": "thread-provenance-revalidation",
                "sessionId": "session-provenance-revalidation",
                "parentThreadId": "thread-parent-revalidation",
                "source": {"custom": "chatgpt"},
                "gitInfo": {
                  "sha": "2222222222222222",
                  "branch": "feature/second",
                  "originUrl": "git@github.com:lynnswap/CodexKit.git"
                }
              }],
              "nextCursor": null
            }
            """
        )
        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(await eventually { recorder.transactions.count >= 2 })
        let transaction = try #require(recorder.transactions.first { transaction in
            transaction.reason == .revalidate
                && transaction.itemChanges.contains(
                    .update(itemID: chat.id, indexPath: .init(section: 0, item: 0))
                )
        })
        #expect(transaction.reason == .revalidate)
        #expect(results.items.first === chat)
        #expect(chat.source == .custom("chatgpt"))
        #expect(chat.sourceKind == nil)
        #expect(chat.gitInfo?.sha == "2222222222222222")
        #expect(chat.gitInfo?.branch == "feature/second")

        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [{"id": "thread-provenance-revalidation"}],
              "nextCursor": null
            }
            """
        )
        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(results.items.first === chat)
        #expect(chat.sessionID == "session-provenance-revalidation")
        #expect(chat.parentThreadID == "thread-parent-revalidation")
        #expect(chat.source == .custom("chatgpt"))
        #expect(chat.gitInfo?.branch == "feature/second")

        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [{
                "id": "thread-provenance-revalidation",
                "sessionId": null,
                "parentThreadId": null,
                "source": null,
                "gitInfo": null
              }],
              "nextCursor": null
            }
            """
        )
        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(results.items.isEmpty)
        #expect(context.registeredModel(for: chat.id) === chat)
        #expect(chat.sessionID == nil)
        #expect(chat.parentThreadID == nil)
        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)
        #expect(chat.gitInfo == nil)
    }

    @Test("exact source pages preserve prior source metadata when a later snapshot omits it")
    func exactSourcePagesPreserveOmittedSourceMetadata() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-source-memory", name: "Before")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedSourceKindChatPredicate(
                archived: false,
                sourceKinds: [.appServer]
            )
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadList(.init(profile: .partialDTO, threads: [
            .init(id: "thread-source-memory", name: "After")
        ]))
        try await results.refresh()

        #expect(results.items.first === chat)
        #expect(chat.title == "After")
        #expect(chat.source == .appServer)
        #expect(chat.sourceKind == .appServer)
    }

    @Test("registered chat lookup does not create placeholders")
    func registeredChatLookupDoesNotCreatePlaceholders() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID = CodexThreadID(rawValue: "thread-unloaded")

        #expect(context.registeredModel(for: threadID) == nil)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").isEmpty)

        let placeholder = context.model(for: threadID)

        #expect(placeholder.id == threadID)
        #expect(placeholder.source == nil)
        #expect(placeholder.sourceKind == nil)
        #expect(context.registeredModel(for: threadID) === placeholder)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").isEmpty)
    }

    @Test("seeded app-server test runtime drives DataKit through public APIs")
    func seededAppServerRuntimeDrivesDataKitThroughPublicAPIs() async throws {
        let workspace = temporaryDirectory()
        let stored = try makeDataKitStoredThreadFixture(
            id: "thread-seeded",
            workspace: workspace,
            name: "Seeded review",
            preview: "Loaded from fake app-server",
            modelProvider: "gpt-test",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            stored
        ])
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()

        let chat = try #require(results.items.first)
        #expect(chat.title == "Seeded review")
        #expect(chat.preview == "Loaded from fake app-server")
        #expect(chat.modelProvider == "gpt-test")
        #expect(chat.workspace?.url == workspace)

        try await context.refresh(chat, includeTurns: false)
        #expect(chat.title == "Seeded review")
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").count == 1)
    }

    @Test("seeded app-server test runtime supports starting chats through DataKit")
    func seededAppServerRuntimeSupportsStartingChatsThroughDataKit() async throws {
        let workspaceURL = temporaryDirectory()
        let existing = try makeDataKitStoredThreadFixture(
            id: "thread-existing",
            workspace: workspaceURL,
            name: "Existing"
        )
        let plannedStart = try makeDataKitStoredThreadFixture(
            id: "thread-started",
            workspace: workspaceURL,
            model: "gpt-test",
            ephemeral: true
        )
        let store = try CodexAppServerTestThreadStore(
            threads: [existing],
            plannedStarts: [plannedStart]
        )
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let workspaces = try await context.fetch(CodexFetchDescriptor<CodexWorkspace>.workspaces)
        let workspace = try #require(workspaces.first)

        let chat = try await workspace.startChat(.init(
            options: .init(model: "gpt-test", modelProvider: "openai", ephemeral: true)
        ))
        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(chats.first === chat)
        #expect(chat.workspace === workspace)
        #expect(chat.modelProvider == "openai")
        #expect(chat.ephemeral == true)

        let startRequest = try #require(
            await runtime.transport.recordedRequests(method: "thread/start").first)
        let params = try startRequest.decodeParams(ThreadStartParams.self)
        #expect(params.cwd == workspaceURL.path)
        #expect(params.model == "gpt-test")
        #expect(params.modelProvider == "openai")
        #expect(params.ephemeral == true)
    }

    @Test("opaque stored-thread refresh keeps review output scoped to its turn")
    func opaqueStoredThreadRefreshKeepsReviewOutputScopedToItsTurn() async throws {
        let workspace = temporaryDirectory()
        let firstItem = try CodexAppServerTestItem.exitedReviewMode(
            id: "review-output-first",
            review: "First review"
        )
        let secondItem = try CodexAppServerTestItem.exitedReviewMode(
            id: "review-output-second",
            review: "Second review"
        )
        let firstTurn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-first",
                state: .completed,
                items: [firstItem.domainProjection]
            ),
            items: [firstItem]
        )
        let secondTurn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-second",
                state: .completed,
                items: [secondItem.domainProjection]
            ),
            items: [secondItem]
        )
        let stored = try makeDataKitStoredThreadFixture(
            id: "thread-review-output",
            workspace: workspace,
            turns: [firstTurn, secondTurn]
        )
        let runtime = try await CodexAppServerTestRuntime.start(threads: [stored])
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats
        )
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await context.refresh(chat, includeTurns: true)

        let firstItemIDs = chat.items(in: firstTurn.snapshot.id).map(\.itemID)
        let secondItemIDs = chat.items(in: secondTurn.snapshot.id).map(\.itemID)
        #expect(chat.transcript(in: firstTurn.snapshot.id).reviewOutputText == "First review")
        #expect(chat.transcript(in: secondTurn.snapshot.id).reviewOutputText == "Second review")
        #expect(firstItemIDs == ["review-output-first"])
        #expect(secondItemIDs == ["review-output-second"])
    }

    @Test("opaque stored-thread refresh preserves review rollout semantic metadata")
    func opaqueStoredThreadRefreshPreservesReviewRolloutSemanticMetadata() async throws {
        let workspace = temporaryDirectory()
        let assistant = try CodexAppServerTestItem.agentMessage(
            id: "review_rollout_assistant",
            text: "review output"
        )
        let turn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-review",
                state: .completed,
                items: [assistant.domainProjection]
            ),
            items: [assistant]
        )
        let stored = try makeDataKitStoredThreadFixture(
            id: "thread-review-metadata",
            workspace: workspace,
            turns: [turn]
        )
        let runtime = try await CodexAppServerTestRuntime.start(threads: [stored])
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats
        )
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await context.refresh(chat, includeTurns: true)

        let item = try #require(chat.items(in: turn.snapshot.id).first)
        #expect(item.origin == .reviewRolloutAssistant)
        #expect(item.semanticRelation == .companionOf(.exitedReviewMode))
        let transcriptItem = try #require(chat.transcript(in: turn.snapshot.id).items.first)
        #expect(transcriptItem.origin == .reviewRolloutAssistant)
        #expect(transcriptItem.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("fetch requests are translated to app-server thread/list query params")
    func fetchRequestTranslatesToThreadListParams() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(
            CodexAppServerTestThreadPage(threads: [])
        )

        let request = CodexFetchDescriptor<CodexChat>(
            predicate: fullThreadListChatPredicate(
                archived: true,
                workspace: workspace,
                searchTerm: "needle",
                modelProviders: ["gpt-5"],
                sourceKinds: [.appServer, .subAgent]
            ),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 25
        )

        _ = try await context.fetch(request)

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == true)
        #expect(params.cursor == nil)
        #expect(params.cwd == .paths([workspace.path]))
        #expect(params.limit == nil)
        #expect(params.searchTerm == nil)
        #expect(params.modelProviders == ["gpt-5"])
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "recency_at")
        #expect(params.sourceKinds == ["appServer", "subAgent"])
        #expect(params.useStateDbOnly == nil)
    }

    @Test("default chat fetches compose every user-visible source partition")
    func defaultChatFetchesComposeUserVisibleSourcePartitions() async throws {
        let workspace = temporaryDirectory()
        let sources: [(id: String, sourceKind: CodexThreadSourceKind)] = [
            ("thread-cli", .cli),
            ("thread-atlas", .init(rawValue: "atlas")),
            ("thread-exec", .exec),
            ("thread-app-server", .appServer),
            ("thread-review", .subAgentReview),
            ("thread-compact", .subAgentCompact),
            ("thread-spawn", .subAgentThreadSpawn),
            ("thread-other", .subAgentOther),
            ("thread-unknown", .unknown),
            ("thread-memory", .subAgent),
        ]
        let threads = try sources.enumerated().map { offset, source in
            try DataKitTestThreadFixture(
                id: .init(rawValue: source.id),
                workspace: workspace,
                name: source.id,
                sourceKind: source.sourceKind,
                createdAt: Date(timeIntervalSince1970: Double(offset + 1)),
                recencyAt: Date(timeIntervalSince1970: Double(offset + 1))
            ).storedThread(profile: .currentV2)
        }
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(Set(chats.map(\.id.rawValue)) == [
            "thread-cli",
            "thread-atlas",
            "thread-exec",
            "thread-app-server",
            "thread-review",
            "thread-compact",
            "thread-spawn",
            "thread-other",
            "thread-unknown",
        ])
        #expect(chats.contains { $0.id == "thread-memory" } == false)
        let atlas = try #require(chats.first { $0.id == "thread-atlas" })
        #expect(atlas.source == .custom("atlas"))
        #expect(atlas.sourceKind == nil)

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.count == 2)
        #expect(params[0].sourceKinds == nil)
        #expect(params[1].sourceKinds == [
            "exec",
            "appServer",
            "subAgentReview",
            "subAgentCompact",
            "subAgentThreadSpawn",
            "subAgentOther",
            "unknown",
        ])
    }

    @Test("default workspace and group fetches compose user-visible source partitions")
    func defaultWorkspaceAndGroupFetchesComposeUserVisibleSources() async throws {
        let visibleRepo = try gitRepository(named: "Visible")
        let memoryRepo = try gitRepository(named: "Memory")
        let appServerWorkspace = try createDirectory("App", in: visibleRepo)
        let customWorkspace = try createDirectory("Tools", in: visibleRepo)
        let memoryWorkspace = try createDirectory("Internal", in: memoryRepo)
        let threads = try [
            DataKitTestThreadFixture(
                id: "thread-app-server",
                workspace: appServerWorkspace,
                sourceKind: .appServer
            ).storedThread(profile: .currentV2),
            DataKitTestThreadFixture(
                id: "thread-atlas",
                workspace: customWorkspace,
                sourceKind: .init(rawValue: "atlas")
            ).storedThread(profile: .currentV2),
            DataKitTestThreadFixture(
                id: "thread-memory",
                workspace: memoryWorkspace,
                sourceKind: .subAgent
            ).storedThread(profile: .currentV2),
        ]
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let workspaces = try await context.fetch(
            CodexFetchDescriptor<CodexWorkspace>.workspaces
        )
        let groups = try await context.fetch(
            CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups
        )

        let expectedWorkspaceURLs = Set([
            appServerWorkspace.standardizedFileURL.resolvingSymlinksInPath(),
            customWorkspace.standardizedFileURL.resolvingSymlinksInPath(),
        ])
        #expect(Set(workspaces.map(\.url)) == expectedWorkspaceURLs)
        #expect(groups.count == 1)
        #expect(Set(groups.flatMap(\.workspaces).map(\.url)) == expectedWorkspaceURLs)

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.count == 4)
        #expect(params[0].sourceKinds == nil)
        #expect(params[1].sourceKinds != nil)
        #expect(params[2].sourceKinds == nil)
        #expect(params[3].sourceKinds != nil)
    }

    @Test("unbounded composite fetch accepts sparse responses proven by source partitions")
    func unboundedCompositeFetchAcceptsSparsePartitionResponses() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(
                    id: "thread-newer",
                    name: "Newer",
                    updatedAt: Date(timeIntervalSince1970: 200),
                    recencyAt: Date(timeIntervalSince1970: 200)
                ),
                .init(
                    id: "thread-older",
                    name: "Older",
                    updatedAt: Date(timeIntervalSince1970: 100),
                    recencyAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        ))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(chats.map(\.id.rawValue) == ["thread-newer", "thread-older"])
        #expect(chats.allSatisfy { $0.source == nil && $0.sourceKind == nil })
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.count == 2)
        #expect(params.allSatisfy { $0.limit == nil })
    }

    @Test("incomplete source and search predicates accept sparse partition members and apply residuals")
    func incompleteSourceSearchPredicateAcceptsSparsePartitionMembers() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(id: "thread-search-match", name: "needle match"),
                .init(id: "thread-search-miss", name: "different"),
            ]
        ))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindSearchChatPredicate(.appServer, searchTerm: "needle"),
            sortBy: [CodexSortDescriptor(\.name)]
        ))

        #expect(chats.map(\.id.rawValue) == ["thread-search-match"])
        #expect(chats.first?.source == nil)
        #expect(chats.first?.sourceKind == nil)
        let request = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first
        )
        let params = try request.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["appServer"])
        #expect(params.searchTerm == nil)
    }

    @Test("complete server predicates retain authority after sparse source evidence is validated")
    func completeServerPredicatesAcceptSparseNonSourceFields() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()
        try await runtime.transport.enqueueThreadList(.init(
            profile: .partialDTO,
            threads: [.init(id: "thread-complete-sparse", name: "Sparse")]
        ))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: nonOptionalFieldEqualityChatPredicate(
                workspace: workspace,
                modelProvider: "openai",
                sourceKind: .appServer
            ),
            sortBy: [CodexSortDescriptor(\.name)]
        ))

        #expect(chats.map(\.id.rawValue) == ["thread-complete-sparse"])
        #expect(chats.first?.workspace?.url == workspace)
        #expect(chats.first?.modelProvider == nil)
        #expect(chats.first?.source == nil)
        #expect(chats.first?.sourceKind == nil)
    }

    @Test("created-at composite fallback accepts sparse responses before local paging")
    func createdAtCompositeFallbackAcceptsSparseResponses() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(
                    id: "thread-created-older",
                    createdAt: Date(timeIntervalSince1970: 100)
                ),
                .init(
                    id: "thread-created-newer",
                    createdAt: Date(timeIntervalSince1970: 200)
                ),
            ]
        ))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.createdAt, order: .reverse)],
            fetchLimit: 1
        ))

        #expect(chats.map(\.id.rawValue) == ["thread-created-newer"])
        #expect(chats.first?.source == nil)
        #expect(chats.first?.sourceKind == nil)
        #expect(context.registeredModel(for: CodexThreadID("thread-created-older")) != nil)
    }

    @Test("unsorted composite fallback accepts sparse responses with effective ordering")
    func unsortedCompositeFallbackAcceptsSparseResponses() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(
                    id: "thread-unsorted-older",
                    createdAt: Date(timeIntervalSince1970: 100)
                ),
                .init(
                    id: "thread-unsorted-newer",
                    createdAt: Date(timeIntervalSince1970: 200)
                ),
            ]
        ))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false)
        ))

        #expect(chats.map(\.id.rawValue) == [
            "thread-unsorted-newer",
            "thread-unsorted-older",
        ])
        #expect(chats.allSatisfy { $0.source == nil && $0.sourceKind == nil })
    }

    @Test("direct complete source pages accept sparse server responses")
    func directCompleteSourcePagesAcceptSparseResponses() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(
                    id: "thread-direct-sparse",
                    name: "Direct",
                    recencyAt: Date(timeIntervalSince1970: 100)
                )
            ],
            nextCursor: "direct-next"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 10
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-direct-sparse"])
        #expect(results.items.first?.source == nil)
        #expect(results.items.first?.sourceKind == nil)
        #expect(results.nextCursor == "direct-next")
        let request = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first
        )
        let params = try request.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["appServer"])
        #expect(params.limit == 10)
    }

    @Test("sparse explicit source results survive metadata-only local revalidation")
    func sparseExplicitSourceResultsSurviveLocalRevalidation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(id: "thread-beta-sparse", name: "Beta"),
                .init(id: "thread-zulu-sparse", name: "Zulu"),
            ]
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer),
            sortBy: [CodexSortDescriptor(\.name)]
        ))

        try await results.performFetch()

        let zulu = try #require(results.items.first { $0.id == "thread-zulu-sparse" })
        #expect(results.items.map(\.title) == ["Beta", "Zulu"])
        #expect(zulu.source == nil)
        #expect(zulu.sourceKind == nil)

        try await runtime.transport.enqueueThreadResume(.init(id: zulu.id))
        try await runtime.transport.enqueue(
            AppServerAPI.Thread.Read.Response(thread: DataKitTestThreadFixture(
                id: zulu.id,
                name: "Aardvark"
            ).dto(profile: .partialDTO)),
            for: "thread/read"
        )
        try await context.refresh(zulu, includeTurns: false)

        #expect(results.items.map(\.title) == ["Aardvark", "Beta"])
        #expect(results.items.first === zulu)
        #expect(Set(results.items.map(\.id)).count == 2)
        #expect(zulu.source == nil)
        #expect(zulu.sourceKind == nil)
    }

    @Test("duplicate direct-page source occurrences return one item")
    func duplicateDirectPageSourceOccurrencesReturnOneItem() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(id: "thread-direct-duplicate", name: "First", sourceKind: .appServer),
                .init(id: "thread-direct-duplicate", name: "Second", sourceKind: .appServer),
            ]
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 10
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-direct-duplicate"])
        let chat = try #require(results.items.first)
        #expect(chat.title == "Second")
        #expect(chat.sourceKind == .appServer)
    }

    @Test("duplicate partition occurrences do not replace explicit null with omitted proof")
    func duplicatePartitionOccurrencesPreserveExplicitNull() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueJSON(
            """
            {
              "data": [
                {"id": "thread-duplicate-null", "name": "First", "source": null}
              ],
              "nextCursor": null
            }
            """,
            for: "thread/list"
        )
        try await runtime.transport.enqueueThreadList(.init(
            profile: .partialDTO,
            threads: [.init(id: "thread-duplicate-null", name: "Second")]
        ))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(chats.isEmpty)
        let chat = try #require(
            context.registeredModel(for: CodexThreadID("thread-duplicate-null"))
        )
        #expect(chat.title == "Second")
        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)
    }

    @Test("local live chats require server provenance before local insertion")
    func localLiveChatsRequireServerProvenance() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let localChat = context.model(for: CodexThreadID("thread-local-live"))
        localChat.apply(
            .init(id: localChat.id, status: .active(activeFlags: [])),
            workspace: nil
        )
        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: []
        ))
        let descriptor = CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.name)]
        )
        let results = context.fetchedResults(for: descriptor)

        try await results.performFetch()

        #expect(results.items.isEmpty)
        #expect(context.registeredModel(for: localChat.id) === localChat)
        #expect(localChat.status?.isActive == true)
        #expect(localChat.source == nil)
        #expect(localChat.sourceKind == nil)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: [.init(id: localChat.id, name: "Server proven")]
        ))
        _ = try await context.fetch(descriptor)

        #expect(results.items.first === localChat)
        #expect(localChat.status?.isActive == true)
        #expect(localChat.source == nil)
        #expect(localChat.sourceKind == nil)
    }

    @Test("bounded composite pages fall back when an invalid prefix hides valid rows")
    func boundedCompositePagesFallBackForInvalidPrefixes() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let invalidID = CodexThreadID("thread-bounded-known-null")
        let invalidChat = context.model(for: invalidID)
        invalidChat.apply(
            .init(
                id: invalidID,
                recencyAt: Date(timeIntervalSince1970: 300),
                turnItemsAreAuthoritative: false,
                presentFields: [.source, .recencyAt]
            ),
            workspace: nil
        )
        let prefix = try DataKitTestThreadPage(
            profile: .partialDTO,
            threads: [
                .init(
                    id: invalidID,
                    name: "Invalid",
                    recencyAt: Date(timeIntervalSince1970: 300)
                ),
                .init(
                    id: "thread-bounded-valid-1",
                    name: "Valid 1",
                    recencyAt: Date(timeIntervalSince1970: 200)
                ),
            ],
            nextCursor: "bounded-invalid-next"
        )
        try await runtime.transport.enqueueThreadList(prefix)
        try await runtime.transport.enqueueThreadList(.init(profile: .partialDTO, threads: []))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(
                    id: invalidID,
                    name: "Invalid",
                    recencyAt: Date(timeIntervalSince1970: 300)
                ),
                .init(
                    id: "thread-bounded-valid-1",
                    name: "Valid 1",
                    recencyAt: Date(timeIntervalSince1970: 200)
                ),
                .init(
                    id: "thread-bounded-valid-2",
                    name: "Valid 2",
                    recencyAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 2
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == [
            "thread-bounded-valid-1",
            "thread-bounded-valid-2",
        ])
        #expect(results.nextCursor == nil)
        #expect(context.registeredModel(for: invalidID) === invalidChat)
        #expect(invalidChat.source == nil)
        #expect(invalidChat.sourceKind == nil)
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.count == 4)
        #expect(params[0].limit == 2)
        #expect(params[1].limit == 2)
        #expect(params[2].limit == nil)
        #expect(params[3].limit == nil)
    }

    @Test("bounded composite chat pages use global recency ordering without registering off-page chats")
    func boundedCompositeChatPagesUseGlobalRecencyOrdering() async throws {
        let workspace = temporaryDirectory()
        let threadIDs = (0..<30).map { String(format: "thread-%02d", $0) }
        let threads = try threadIDs.enumerated().map { offset, threadID in
            try DataKitTestThreadFixture(
                id: .init(rawValue: threadID),
                workspace: workspace,
                name: threadID,
                sourceKind: offset.isMultiple(of: 2) ? .cli : .appServer,
                recencyAt: Date(timeIntervalSince1970: TimeInterval(1_000 - offset))
            ).storedThread(profile: .currentV2)
        }
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 10
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == Array(threadIDs.prefix(10)))
        #expect(results.nextCursor == context.localCursor(for: 10))
        for threadID in threadIDs.dropFirst(10) {
            #expect(context.registeredModel(for: CodexThreadID(rawValue: threadID)) == nil)
        }

        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue) == Array(threadIDs.prefix(20)))
        #expect(Set(results.items.map(\.id.rawValue)).count == 20)
        #expect(results.nextCursor == context.localCursor(for: 20))
        for threadID in threadIDs.dropFirst(20) {
            #expect(context.registeredModel(for: CodexThreadID(rawValue: threadID)) == nil)
        }

        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue) == threadIDs)
        #expect(Set(results.items.map(\.id.rawValue)).count == 30)
        #expect(results.nextCursor == nil)

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 6)
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.map(\.limit) == [10, 10, 20, 20, 30, 30])
        for requestParams in params {
            #expect(requestParams.cursor == nil)
            #expect(requestParams.archived == false)
            #expect(requestParams.sortDirection == "desc")
            #expect(requestParams.sortKey == "recency_at")
        }
        #expect(params[0].sourceKinds == nil)
        #expect(params[1].sourceKinds != nil)
        #expect(params[2].sourceKinds == nil)
        #expect(params[3].sourceKinds != nil)
        #expect(params[4].sourceKinds == nil)
        #expect(params[5].sourceKinds != nil)
    }

    @Test("bounded composite chat pages expose local backwards cursors")
    func boundedCompositeChatPagesExposeLocalBackwardsCursors() async throws {
        let workspace = temporaryDirectory()
        let threadIDs = (0..<30).map { String(format: "thread-%02d", $0) }
        let threads = try threadIDs.enumerated().map { offset, threadID in
            try DataKitTestThreadFixture(
                id: .init(rawValue: threadID),
                workspace: workspace,
                sourceKind: offset.isMultiple(of: 2) ? .cli : .appServer,
                recencyAt: Date(timeIntervalSince1970: TimeInterval(1_000 - offset))
            ).storedThread(profile: .currentV2)
        }
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 10,
            fetchOffset: 10
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == Array(threadIDs[10..<20]))
        #expect(results.nextCursor == context.localCursor(for: 20))
        #expect(results.backwardsCursor == context.localCursor(for: 0))
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.map(\.limit) == [20, 20])
    }

    @Test("bounded composite pages accept source metadata omissions proven by their partition")
    func boundedCompositePagesAcceptPartitionProvenSourceOmissions() async throws {
        let workspace = temporaryDirectory()
        let page = try DataKitTestThreadPage(
            profile: .partialDTO,
            threads: [
                .init(
                    id: "thread-newer",
                    workspace: workspace,
                    name: "Newer",
                    recencyAt: Date(timeIntervalSince1970: 200)
                ),
                .init(
                    id: "thread-older",
                    workspace: workspace,
                    name: "Older",
                    recencyAt: Date(timeIntervalSince1970: 100)
                ),
            ],
            nextCursor: "interactive-next"
        )
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(page)
        try await runtime.transport.enqueueThreadList(.init(profile: .partialDTO, threads: []))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 2
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-newer", "thread-older"])
        #expect(results.nextCursor == context.localCursor(for: 2))
        #expect(results.items.allSatisfy { $0.source == nil && $0.sourceKind == nil })
        for chat in results.items {
            #expect(context.registeredModel(for: chat.id) === chat)
            #expect(chat.workspace?.url == workspace)
        }
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.map(\.limit) == [2, 2])
        #expect(params[0].sourceKinds == nil)
        #expect(params[1].sourceKinds != nil)
    }

    @Test("bounded composite partitions refill after the server page-size clamp")
    func boundedCompositePartitionsRefillAfterServerPageSizeClamp() async throws {
        let workspace = temporaryDirectory()
        let threadIDs = (0..<130).map { String(format: "thread-%03d", $0) }
        let threads = try threadIDs.enumerated().map { offset, threadID in
            try DataKitTestThreadFixture(
                id: .init(rawValue: threadID),
                workspace: workspace,
                sourceKind: .cli,
                recencyAt: Date(timeIntervalSince1970: TimeInterval(10_000 - offset))
            ).storedThread(profile: .currentV2)
        }
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 125
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == Array(threadIDs.prefix(125)))
        #expect(results.nextCursor == context.localCursor(for: 125))
        for threadID in threadIDs.dropFirst(125) {
            #expect(context.registeredModel(for: CodexThreadID(rawValue: threadID)) == nil)
        }
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try requests.map { try $0.decodeParams(ThreadListParams.self) }
        #expect(params.count == 3)
        #expect(params.map(\.limit) == [125, 25, 125])
        #expect(params[0].cursor == nil)
        #expect(params[1].cursor != nil)
        #expect(params[2].cursor == nil)
        #expect(params[0].sourceKinds == nil)
        #expect(params[1].sourceKinds == nil)
        #expect(params[2].sourceKinds != nil)
    }

    @Test("bounded composite page append restores global order around a preserved live chat")
    func boundedCompositePageAppendRestoresGlobalOrderAroundPreservedLiveChat() async throws {
        let workspace = temporaryDirectory()
        let threadIDs = (0..<30).map { String(format: "thread-%02d", $0) }
        let threads = try threadIDs.enumerated().map { offset, threadID in
            try DataKitTestThreadFixture(
                id: .init(rawValue: threadID),
                workspace: workspace,
                sourceKind: offset.isMultiple(of: 2) ? .cli : .appServer,
                recencyAt: Date(timeIntervalSince1970: TimeInterval(1_000 - offset)),
                status: offset == 15 ? .active(activeFlags: []) : .idle
            ).storedThread(profile: .currentV2)
        }
        let interactiveThreads = threads.enumerated().compactMap { offset, thread in
            offset.isMultiple(of: 2) ? thread : nil
        }
        let noninteractiveThreads = threads.enumerated().compactMap { offset, thread in
            offset.isMultiple(of: 2) ? nil : thread
        }
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [threads[15]]))
        let liveChats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer)
        ))
        let liveChat = try #require(liveChats.first)
        #expect(liveChat.status?.isActive == true)

        try await runtime.transport.enqueueThreadList(.init(threads: interactiveThreads))
        try await runtime.transport.enqueueThreadList(.init(threads: noninteractiveThreads))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 10
        ))
        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == Array(threadIDs.prefix(10)) + [threadIDs[15]])
        #expect(results.items.last === liveChat)

        try await runtime.transport.enqueueThreadList(.init(threads: interactiveThreads))
        try await runtime.transport.enqueueThreadList(.init(threads: noninteractiveThreads))
        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue) == Array(threadIDs.prefix(20)))
        #expect(results.items[15] === liveChat)
    }

    @Test("final bounded composite page completes relationship reconciliation")
    func finalBoundedCompositePageCompletesRelationshipReconciliation() async throws {
        let workspaceURL = temporaryDirectory()
        let stale = try DataKitTestThreadFixture(
            id: "thread-stale",
            workspace: workspaceURL,
            sourceKind: .cli,
            recencyAt: Date(timeIntervalSince1970: 400)
        ).storedThread(profile: .currentV2)
        let first = try DataKitTestThreadFixture(
            id: "thread-first",
            workspace: workspaceURL,
            sourceKind: .cli,
            recencyAt: Date(timeIntervalSince1970: 300)
        ).storedThread(profile: .currentV2)
        let second = try DataKitTestThreadFixture(
            id: "thread-second",
            workspace: workspaceURL,
            sourceKind: .appServer,
            recencyAt: Date(timeIntervalSince1970: 200)
        ).storedThread(profile: .currentV2)
        let third = try DataKitTestThreadFixture(
            id: "thread-third",
            workspace: workspaceURL,
            sourceKind: .cli,
            recencyAt: Date(timeIntervalSince1970: 100)
        ).storedThread(profile: .currentV2)
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: [stale]))
        let staleChats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli)
        ))
        let staleChat = try #require(staleChats.first)
        let workspace = try #require(staleChat.workspace)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [first],
            nextCursor: "interactive-more"
        ))
        try await runtime.transport.enqueueThreadList(.init(
            threads: [second],
            nextCursor: "noninteractive-more"
        ))
        try await runtime.transport.enqueueThreadList(.init(threads: [first, third]))
        try await runtime.transport.enqueueThreadList(.init(threads: [second]))
        try await runtime.transport.enqueueThreadList(.init(threads: [first, third]))
        try await runtime.transport.enqueueThreadList(.init(threads: [second]))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(workspace.chats.contains { $0 === staleChat })

        try await results.loadNextPage()
        #expect(workspace.chats.contains { $0 === staleChat })

        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue) == [
            "thread-first",
            "thread-second",
            "thread-third",
        ])
        #expect(results.nextCursor == nil)
        #expect(workspace.chats.contains { $0 === staleChat } == false)
        #expect(Set(workspace.chats.map(\.id.rawValue)) == [
            "thread-first",
            "thread-second",
            "thread-third",
        ])
    }

    @Test("final offset composite page preserves relationships before the configured offset")
    func finalOffsetCompositePagePreservesPreOffsetRelationships() async throws {
        let workspaceURL = temporaryDirectory()
        let threadIDs = (0..<30).map { String(format: "thread-%02d", $0) }
        let threads = try threadIDs.enumerated().map { offset, threadID in
            try DataKitTestThreadFixture(
                id: .init(rawValue: threadID),
                workspace: workspaceURL,
                sourceKind: offset.isMultiple(of: 2) ? .cli : .appServer,
                recencyAt: Date(timeIntervalSince1970: TimeInterval(1_000 - offset))
            ).storedThread(profile: .currentV2)
        }
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let seed = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        let preOffsetChat = try #require(seed.first)
        let workspace = try #require(preOffsetChat.workspace)
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 10,
            fetchOffset: 10
        ))

        try await results.performFetch()
        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue) == Array(threadIDs[10..<30]))
        #expect(results.nextCursor == nil)
        #expect(workspace.chats.contains { $0 === preOffsetChat })
    }

    @Test("bounded composite fetch applies no snapshots when a later partition fails")
    func boundedCompositeFetchIsAtomicAcrossSourcePartitions() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstPartitionChat = try DataKitTestThreadFixture(
            id: "thread-first-partition",
            sourceKind: .cli,
            recencyAt: Date(timeIntervalSince1970: 1_000)
        ).storedThread(profile: .currentV2)
        try await runtime.transport.enqueueThreadList(.init(threads: [firstPartitionChat]))
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "second partition failed",
            for: "thread/list"
        )

        do {
            _ = try await context.fetch(CodexFetchDescriptor<CodexChat>(
                predicate: archivedChatPredicate(false),
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
                fetchLimit: 10
            ))
            Issue.record("Expected the second source partition to fail")
        } catch CodexFetchFailure.appServer {
        }

        #expect(context.registeredModel(for: firstPartitionChat.snapshot.id) == nil)
        let workspace = try #require(firstPartitionChat.snapshot.workspace)
        #expect(context.registeredModel(for: testWorkspaceID(for: workspace)) == nil)
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 2)
    }

    @Test("bounded composite cancellation before apply leaves both partitions unregistered")
    func boundedCompositeCancellationBeforeApplyIsAtomic() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstGate = CodexAppServerTestGate()
        let secondGate = CodexAppServerTestGate()
        let first = try DataKitTestThreadFixture(
            id: "thread-first-cancelled",
            workspace: temporaryDirectory(),
            sourceKind: .cli,
            recencyAt: Date(timeIntervalSince1970: 1_000)
        ).storedThread(profile: .currentV2)
        let second = try DataKitTestThreadFixture(
            id: "thread-second-cancelled",
            workspace: temporaryDirectory(),
            sourceKind: .appServer,
            recencyAt: Date(timeIntervalSince1970: 900)
        ).storedThread(profile: .currentV2)

        try await runtime.transport.enqueueThreadList(.init(threads: [first]))
        try await runtime.transport.enqueueThreadList(.init(threads: [second]))
        await runtime.transport.holdNext(method: "thread/list", gate: firstGate)
        let fetch = Task { @MainActor in
            _ = try await context.fetch(CodexFetchDescriptor<CodexChat>(
                predicate: archivedChatPredicate(false),
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
                fetchLimit: 10
            ))
        }

        await runtime.transport.waitForRequest(method: "thread/list", count: 1)
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/list",
            gate: secondGate
        )
        await firstGate.open()
        await runtime.transport.waitForRequest(method: "thread/list", count: 2)
        fetch.cancel()
        await secondGate.open()
        do {
            try await fetch.value
            Issue.record("Expected the composite fetch to be cancelled")
        } catch is CancellationError {
        }

        #expect(context.registeredModel(for: first.snapshot.id) == nil)
        #expect(context.registeredModel(for: second.snapshot.id) == nil)
        let firstWorkspace = try #require(first.snapshot.workspace)
        let secondWorkspace = try #require(second.snapshot.workspace)
        #expect(context.registeredModel(for: testWorkspaceID(for: firstWorkspace)) == nil)
        #expect(context.registeredModel(for: testWorkspaceID(for: secondWorkspace)) == nil)
    }

    @Test("cancelled bounded fallback does not apply exhaustive candidates")
    func cancelledBoundedFallbackDoesNotApplyExhaustiveCandidates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let passGate = CodexAppServerTestGate()
        let finalGate = CodexAppServerTestGate()
        let invalidWorkspace = temporaryDirectory()
        let firstWorkspace = temporaryDirectory()
        let secondWorkspace = temporaryDirectory()
        let fastResponse =
            """
            {
              "data": [
                {
                  "id": "thread-fallback-invalid",
                  "cwd": "\(invalidWorkspace.path)",
                  "source": null,
                  "recencyAt": 300
                },
                {
                  "id": "thread-fallback-first",
                  "cwd": "\(firstWorkspace.path)",
                  "recencyAt": 200
                }
              ],
              "nextCursor": null
            }
            """
        try await runtime.transport.enqueueJSON(fastResponse, for: "thread/list")
        try await runtime.transport.enqueueThreadList(.init(profile: .partialDTO, threads: []))
        try await runtime.transport.enqueueJSON(fastResponse, for: "thread/list")
        try await runtime.transport.enqueueThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(
                    id: "thread-fallback-second",
                    workspace: secondWorkspace,
                    recencyAt: Date(timeIntervalSince1970: 100)
                )
            ]
        ))
        await passGate.open()
        for _ in 0..<3 {
            await runtime.transport.holdNext(method: "thread/list", gate: passGate)
        }
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/list",
            gate: finalGate
        )
        let fetch = Task { @MainActor in
            _ = try await context.fetch(CodexFetchDescriptor<CodexChat>(
                predicate: archivedChatPredicate(false),
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
                fetchLimit: 2
            ))
        }
        await runtime.transport.waitForRequest(method: "thread/list", count: 4)

        fetch.cancel()
        await finalGate.open()
        do {
            try await fetch.value
            Issue.record("Expected the bounded fallback fetch to be cancelled")
        } catch is CancellationError {
        }

        for threadID in [
            "thread-fallback-invalid",
            "thread-fallback-first",
            "thread-fallback-second",
        ] {
            #expect(context.registeredModel(for: CodexThreadID(rawValue: threadID)) == nil)
        }
        for workspace in [invalidWorkspace, firstWorkspace, secondWorkspace] {
            #expect(context.registeredModel(for: testWorkspaceID(for: workspace)) == nil)
        }
    }

    @Test("composite recency fast path falls back for unbounded and created-at fetches")
    func compositeRecencyFastPathFallbacksRemainExhaustive() async throws {
        let workspace = temporaryDirectory()
        let threads = try (0..<30).map { offset in
            try DataKitTestThreadFixture(
                id: .init(rawValue: "thread-\(offset)"),
                workspace: workspace,
                sourceKind: offset.isMultiple(of: 2) ? .cli : .appServer,
                createdAt: Date(timeIntervalSince1970: TimeInterval(offset)),
                recencyAt: Date(timeIntervalSince1970: TimeInterval(1_000 - offset))
            ).storedThread(profile: .currentV2)
        }
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let unbounded = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
        ))
        let createdAt = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.createdAt, order: .reverse)],
            fetchLimit: 5
        ))

        #expect(unbounded.count == 30)
        #expect(createdAt.count == 5)
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 4)
        for request in requests {
            let params = try request.decodeParams(ThreadListParams.self)
            #expect(params.limit == nil)
            #expect(params.sortDirection == "desc")
            #expect(params.sortKey == "recency_at")
        }
    }

    @Test("explicit source predicates keep single-query server paging")
    func explicitSourcePredicatesKeepSingleQueryServerPaging() async throws {
        let workspace = temporaryDirectory()
        let threads = try [
            DataKitTestThreadFixture(
                id: "thread-cli",
                workspace: workspace,
                sourceKind: .cli
            ).storedThread(profile: .currentV2),
            DataKitTestThreadFixture(
                id: "thread-app-server",
                workspace: workspace,
                sourceKind: .appServer
            ).storedThread(profile: .currentV2),
        ]
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))

        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-app-server"])
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 1)
        let params = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(params.limit == 1)
        #expect(params.sourceKinds == ["appServer"])
    }

    @Test("fetch requests pass multiple workspace filters to thread list")
    func fetchRequestTranslatesMultipleWorkspaceFilters() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let app = temporaryDirectory()
        let tools = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))

        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: workspaceChatPredicate([app, tools])
        ))

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.cwd == .paths([app.path, tools.path]))
    }

    @Test("unsorted composite chat fetches reconstruct the global app-server default")
    func unsortedCompositeChatFetchesUseGlobalCreatedAtOrdering() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "recently-active-old-thread",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 400)
            ),
            .init(
                id: "inactive-new-thread",
                createdAt: Date(timeIntervalSince1970: 300),
                updatedAt: Date(timeIntervalSince1970: 300)
            ),
        ]))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "noninteractive-middle-thread",
                sourceKind: .appServer,
                createdAt: Date(timeIntervalSince1970: 200),
                updatedAt: Date(timeIntervalSince1970: 500)
            )
        ]))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>())

        #expect(chats.map(\.id.rawValue) == [
            "inactive-new-thread",
            "noninteractive-middle-thread",
            "recently-active-old-thread",
        ])
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 2)
        for request in requests {
            let params = try request.decodeParams(ThreadListParams.self)
            #expect(params.sortKey == "recency_at")
            #expect(params.sortDirection == "desc")
        }
    }

    @Test("unsorted explicit-source chat fetches preserve app-server ordering")
    func unsortedExplicitSourceChatFetchesPreserveAppServerOrdering() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "recently-active-old-thread",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 400)
            ),
            .init(
                id: "inactive-new-thread",
                createdAt: Date(timeIntervalSince1970: 300),
                updatedAt: Date(timeIntervalSince1970: 300)
            ),
        ]))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli)
        ))

        #expect(chats.map(\.id.rawValue) == [
            "recently-active-old-thread",
            "inactive-new-thread",
        ])
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 1)
        let params = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["cli"])
        #expect(params.sortKey == nil)
        #expect(params.sortDirection == nil)
    }

    @Test("localized search predicates are evaluated without server search pushdown")
    func localizedSearchPredicatesAreEvaluatedWithoutServerSearchPushdown() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-cafe", name: "Café"),
            .init(id: "thread-tea", name: "Tea"),
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: searchChatPredicate("cafe"),
            fetchLimit: 1
        ))

        #expect(results.map(\.id.rawValue) == ["thread-cafe"])
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == false)
        #expect(params.searchTerm == nil)
        #expect(params.limit == nil)
    }

    @Test("disjunction unions preserve incomplete local filters")
    func disjunctionUnionsPreserveIncompleteLocalFilters() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-openai-match", name: "Café", modelProvider: "openai"),
            .init(id: "thread-anthropic-match", name: "Café", modelProvider: "anthropic"),
            .init(id: "thread-openai-miss", name: "Tea", modelProvider: "openai"),
            .init(id: "thread-other-match", name: "Café", modelProvider: "other"),
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: providerSearchDisjunctionChatPredicate(
                firstProvider: "openai",
                secondProvider: "anthropic",
                searchTerm: "cafe"
            ),
            fetchLimit: 1
        ))

        #expect(results.map(\.id.rawValue) == ["thread-openai-match"])
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == false)
        #expect(params.modelProviders == ["openai", "anthropic"])
        #expect(params.searchTerm == nil)
        #expect(params.limit == nil)
    }

    @Test("non-optional captured values match optional chat fields")
    func nonOptionalCapturedValuesMatchOptionalChatFields() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-match",
                workspace: workspace,
                name: "Match",
                modelProvider: "openai",
                sourceKind: .appServer
            )
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: nonOptionalFieldEqualityChatPredicate(
                workspace: workspace,
                modelProvider: "openai",
                sourceKind: .appServer
            )
        ))

        #expect(results.map(\.id.rawValue) == ["thread-match"])
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == false)
        #expect(params.cwd == .paths([workspace.path]))
        #expect(params.modelProviders == ["openai"])
        #expect(params.sourceKinds == ["appServer"])
    }

    @Test("explicit predicates without archive terms fetch active and archived scopes")
    func explicitUnscopedPredicatesFetchBothArchiveScopes() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let provider: String? = "openai"

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-active",
                name: "Active",
                modelProvider: "openai",
                sourceKind: .cli
            )
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-archived",
                name: "Archived",
                modelProvider: "openai",
                sourceKind: .cli
            )
        ]))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: #Predicate<CodexChat> { chat in
                chat.modelProvider == provider
            }
        ))

        #expect(Set(chats.map(\.id.rawValue)) == ["thread-active", "thread-archived"])
        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 4)
        #expect(try requests.map { try $0.decodeParams(ThreadListParams.self).archived } == [
            false,
            false,
            true,
            true,
        ])
    }

    @Test("created and updated sorts enumerate with the stable recency cursor")
    func createdAndUpdatedSortsEnumerateWithStableRecencyCursor() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))

        let descriptor = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 25
        )
        _ = try await context.fetch(descriptor)

        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.limit == nil)
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "recency_at")
    }

    @Test("string sort descriptors honor their comparator")
    func stringSortDescriptorsHonorTheirComparator() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-a2", name: "a2"),
            .init(id: "thread-a10", name: "a10"),
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title, comparator: .lexical)]
        ))

        #expect(results.map(\.id.rawValue) == ["thread-a10", "thread-a2"])
    }

    @Test("string sort descriptor comparators affect query signatures")
    func stringSortDescriptorComparatorsAffectQuerySignatures() {
        let localized = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title, comparator: .localizedStandard)]
        )
        let lexical = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title, comparator: .lexical)]
        )

        #expect(localized.querySignature != lexical.querySignature)
    }

    @Test("fetch descriptor equality uses its normalized semantic query plan")
    func fetchDescriptorEqualityUsesSemanticQueryPlan() {
        requireEquatable(CodexFetchDescriptor<CodexChat>.self)
        let implicitOffset = CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 25
        )
        let explicitOffset = CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 25,
            fetchOffset: 0
        )
        let differentOrder = CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .forward)],
            fetchLimit: 25
        )

        #expect(implicitOffset == explicitOffset)
        #expect(implicitOffset != differentOrder)
    }

    @Test("chat title and name sort descriptors affect query signatures")
    func chatTitleAndNameSortDescriptorsAffectQuerySignatures() {
        let title = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title)]
        )
        let name = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        )

        #expect(title.querySignature != name.querySignature)
    }

    @Test("explicit fetch reports typed validation failures before app-server I/O")
    func explicitFetchReportsTypedValidationFailures() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        do {
            _ = try await context.fetch(CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.preview)]
            ))
            Issue.record("Expected unsupported sort validation failure")
        } catch CodexFetchFailure.validation(.unsupportedSort) {
        }

        do {
            _ = try await context.fetch(CodexFetchDescriptor<CodexChat>(fetchLimit: -1))
            Issue.record("Expected negative fetch limit validation failure")
        } catch CodexFetchFailure.validation(.negativeFetchLimit(-1)) {
        }

        for predicate in [nilSourceKindChatPredicate(), nonNilSourceKindChatPredicate()] {
            do {
                _ = try await context.fetch(CodexFetchDescriptor<CodexChat>(
                    predicate: predicate
                ))
                Issue.record("Expected unsupported source-kind predicate validation failure")
            } catch CodexFetchFailure.validation(.unsupportedPredicate) {
            }
        }

        #expect(await runtime.transport.recordedRequests(method: "thread/list").isEmpty)
    }

    @Test("query plan owns every fetched-results mutation strategy")
    func queryPlanOwnsMutationStrategies() throws {
        let defaultPlan = try CodexThreadQueryPlan(
            descriptor: CodexFetchDescriptor<CodexChat>()
        )
        #expect(defaultPlan.sortPlans.isEmpty)
        #expect(defaultPlan.mutationStrategy(for: .insert) == .refreshLoadedWindow)
        #expect(defaultPlan.mutationStrategy(
            for: .relationshipRefresh
        ) == .refreshLoadedWindow)

        let localPlan = try CodexThreadQueryPlan(descriptor: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.title)]
        ))
        #expect(localPlan.mutationStrategy(for: .insert) == .applyLocally)
        #expect(localPlan.mutationStrategy(for: .archive) == .applyLocally)
        #expect(localPlan.mutationStrategy(
            for: .remove(hasNextPage: false)
        ) == .removeLocally)

        let sourcePlan = try CodexThreadQueryPlan(descriptor: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer),
            sortBy: [CodexSortDescriptor(\.title)]
        ))
        #expect(sourcePlan.mutationStrategy(for: .insert) == .applyLocally)
        #expect(localPlan.mutationStrategy(
            for: .revalidate(affectsMembership: true, hasNextPage: true)
        ) == .refreshLoadedWindow)

        let serverOrderedPlan = try CodexThreadQueryPlan(descriptor: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
        ))
        #expect(serverOrderedPlan.mutationStrategy(for: .insert) == .refreshLoadedWindow)
        #expect(serverOrderedPlan.mutationStrategy(
            for: .relationshipRefresh
        ) == .refreshLoadedWindow)

        let offsetPlan = try CodexThreadQueryPlan(descriptor: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.title)],
            fetchOffset: 1
        ))
        #expect(offsetPlan.mutationStrategy(
            for: .remove(hasNextPage: false)
        ) == .refreshLoadedWindow)
    }

    @Test("non-nil predicates are filtered before applying local fetch limits")
    func nonNilPredicatesFilterBeforeApplyingLocalFetchLimits() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(id: "thread-without-provider", name: "No Provider", sourceKind: .cli),
            .init(
                id: "thread-with-provider",
                name: "Provider",
                modelProvider: "openai",
                sourceKind: .cli
            ),
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: nonNilModelProviderChatPredicate(),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))

        #expect(results.map(\.id.rawValue) == ["thread-with-provider"])
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == false)
        #expect(params.limit == nil)
    }

    @Test("empty membership predicates are filtered before applying local fetch limits")
    func emptyMembershipPredicatesFilterBeforeApplyingLocalFetchLimits() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-openai", name: "OpenAI", modelProvider: "openai"),
            .init(id: "thread-anthropic", name: "Anthropic", modelProvider: "anthropic"),
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: modelProviderChatPredicate([]),
            fetchLimit: 1
        ))

        #expect(results.isEmpty)
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == false)
        #expect(params.limit == nil)
        #expect(params.modelProviders == nil)
    }

    @Test("boolean value predicates are evaluated locally")
    func booleanValuePredicatesAreEvaluatedLocally() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-visible", name: "Visible")
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))

        let trueResults = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: constantChatPredicate(true)
        ))

        #expect(trueResults.map(\.id.rawValue) == ["thread-visible"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-hidden", name: "Hidden")
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))

        let falseResults = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: constantChatPredicate(false),
            fetchLimit: 1
        ))

        #expect(falseResults.isEmpty)
        let recorded = await runtime.transport.recordedRequests(method: "thread/list")
        let falseParams = try #require(recorded.last).decodeParams(ThreadListParams.self)
        #expect(falseParams.archived == true)
        #expect(falseParams.limit == nil)
    }

    @Test("archive inequality predicates translate to archived thread list scope")
    func archiveInequalityPredicatesTranslateToArchivedThreadListScope() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", name: "Archived", sourceKind: .cli)
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: archivedNotEqualChatPredicate(false)
        ))

        #expect(results.map(\.id.rawValue) == ["thread-archived"])
        #expect(results.first?.isArchived == true)
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == true)
    }

    @Test("nil equality predicates merge with archived thread list scope")
    func nilEqualityPredicatesMergeWithArchivedThreadListScope() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(id: "thread-archived", name: "Archived", sourceKind: .cli)
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: archivedNilModelProviderChatPredicate()
        ))

        #expect(results.map(\.id.rawValue) == ["thread-archived"])
        #expect(results.first?.isArchived == true)
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == true)
        #expect(params.limit == nil)
    }

    @Test("archive scopes merge with locally filtered predicates")
    func archiveScopesMergeWithLocallyFilteredPredicates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-match", name: "foo bar"),
            .init(id: "thread-partial", name: "foo")
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: archivedDoubleSearchChatPredicate(
                archived: false,
                first: "foo",
                second: "bar"
            )
        ))

        #expect(results.map(\.id.rawValue) == ["thread-match"])
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.archived == false)
        #expect(params.searchTerm == nil)
        #expect(params.limit == nil)
    }

    @Test("negated compound archive predicates fetch both archive scopes")
    func negatedCompoundArchivePredicatesFetchBothArchiveScopes() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-active-openai", name: "Active OpenAI", modelProvider: "openai"),
            .init(
                id: "thread-active-anthropic",
                name: "Active Anthropic",
                modelProvider: "anthropic"
            ),
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived-openai", name: "Archived OpenAI", modelProvider: "openai")
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: negatedActiveProviderChatPredicate("openai"),
            sortBy: [CodexSortDescriptor(\.title)]
        ))

        #expect(results.map(\.id.rawValue) == [
            "thread-active-anthropic",
            "thread-archived-openai",
        ])
        #expect(results.map(\.isArchived) == [false, true])
        let recorded = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(recorded.count == 4)
        let activeParams = try #require(recorded.first).decodeParams(ThreadListParams.self)
        let archivedParams = try #require(recorded.last).decodeParams(ThreadListParams.self)
        #expect(activeParams.archived == false)
        #expect(archivedParams.archived == true)
        #expect(activeParams.limit == nil)
        #expect(archivedParams.limit == nil)
    }

    @Test("canonical app-server session source matches source filters")
    func canonicalAppServerSessionSourceMatchesSourceFilters() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-legacy", name: "Legacy", sourceKind: .appServer)
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.appServer])
        ))

        #expect(results.map(\.id.rawValue) == ["thread-legacy"])
        #expect(results.first?.source == .appServer)
        #expect(results.first?.sourceKind == .appServer)
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["appServer"])
    }

    @Test("canonical sub-agent review session source matches source filters")
    func canonicalSubAgentReviewSessionSourceMatchesSourceFilters() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-review",
                name: "Review",
                sourceKind: .subAgentReview
            )
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.subAgentReview])
        ))

        #expect(results.map(\.id.rawValue) == ["thread-review"])
        #expect(results.first?.source == .subAgent(.review))
        #expect(results.first?.sourceKind == .subAgentReview)
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["subAgentReview"])
    }

    @Test("unknown source filters exclude custom session sources")
    func unknownSourceFiltersExcludeCustomSessionSources() async throws {
        let workspace = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            try makeDataKitStoredThreadFixture(
                id: "thread-custom-source",
                workspace: workspace,
                source: .custom("automation")
            ),
            try makeDataKitStoredThreadFixture(
                id: "thread-unknown-source",
                workspace: workspace,
                source: .unknown
            ),
        ])
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.unknown])
        ))

        #expect(results.map(\.id.rawValue) == ["thread-unknown-source"])
        #expect(results.first?.source == .unknown)
        #expect(results.first?.sourceKind == .unknown)
    }

    @Test("broad server sub-agent filters preserve leaf predicate semantics")
    func broadServerSubAgentFiltersPreserveLeafPredicateSemantics() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-review", sourceKind: .subAgentReview),
            .init(id: "thread-compact", sourceKind: .subAgentCompact),
            .init(id: "thread-memory", sourceKind: .subAgent),
        ]))

        let results = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.subAgent])
        ))

        #expect(results.map(\.id.rawValue) == ["thread-memory"])
        let recorded = try #require(
            await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try recorded.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["subAgent"])
    }

    @Test("query descriptors accept key path sorts and section aliases")
    func queryDescriptorsAcceptKeyPathSortsAndSectionAliases() {
        let workspaceQuery = CodexQuery<CodexWorkspace>(sort: \.name)
        let chatQuery = CodexQuery<CodexChat>(sort: \.updatedAt, order: .reverse)
        let sectionedChatQuery = CodexQuery<CodexChat>(
            filter: archivedChatPredicate(false),
            sort: \.recencyAt,
            order: .reverse,
            sectionBy: .workspaceGroup
        )
        let requestChatQuery = CodexQuery(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(workspaceQuery.wrappedValue.items.isEmpty)
        #expect(chatQuery.wrappedValue.items.isEmpty)
        #expect(sectionedChatQuery.wrappedValue.items.isEmpty)
        #expect(requestChatQuery.wrappedValue.items.isEmpty)
    }

    @Test("fetched results emits an initial fetch transaction")
    func fetchedResultsEmitsInitialFetchTransaction() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title)]
        ))
        var transactions = results.transactions.makeAsyncIterator()

        try await results.performFetch()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .initialFetch)
        #expect(transaction.isInitialFetch)
        #expect(transaction.oldSnapshot.sections.isEmpty)
        #expect(transaction.newSnapshot.sectionIDs == [.default])
        #expect(transaction.newSnapshot.itemIDs.map(\.rawValue) == ["thread-alpha", "thread-beta"])
        #expect(transaction.sectionChanges == [
            .insert(sectionID: .default, index: 0),
        ])
        #expect(transaction.itemChanges == [
            .insert(
                itemID: CodexThreadID(rawValue: "thread-alpha"),
                indexPath: .init(section: 0, item: 0)
            ),
            .insert(
                itemID: CodexThreadID(rawValue: "thread-beta"),
                indexPath: .init(section: 0, item: 1)
            ),
        ])
        #expect(results.snapshot == transaction.newSnapshot)
        #expect(results.items.map(\.id.rawValue) == ["thread-alpha", "thread-beta"])
        #expect(results.sections.first?.items.first === results.items.first)
    }

    @Test("fetched-results transactions keep only the newest full snapshot transition")
    func fetchedResultsTransactionsBufferNewestSnapshotTransition() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats
        )
        var iterator = results.transactions.makeAsyncIterator()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-a", name: "A")
        ]))
        try await results.performFetch()
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-b", name: "B")
        ]))
        try await results.refresh()

        let transaction = try #require(await iterator.next())
        #expect(transaction.reason == .refresh)
        #expect(transaction.oldSnapshot.itemIDs.map(\.rawValue) == ["thread-a"])
        #expect(transaction.newSnapshot.itemIDs.map(\.rawValue) == ["thread-b"])
    }

    @Test("workspace-group results emits section and item inserts")
    func workspaceGroupControllerEmitsSectionAndItemInserts() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)
        let groupID = try #require(workspace.workspaceGroup?.id)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats,
            sectionedBy: .workspaceGroup
        )
        var transactions = results.transactions.makeAsyncIterator()
        try await results.performFetch()
        _ = await transactions.next()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        let chat = try await workspace.startChat()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .insert)
        #expect(transaction.oldSnapshot.sections.isEmpty)
        #expect(transaction.newSnapshot.sectionIDs == [.workspaceGroup(groupID)])
        #expect(transaction.newSnapshot.itemIDs == [chat.id])
        #expect(transaction.sectionChanges == [
            .insert(sectionID: .workspaceGroup(groupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .insert(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(results.items.first === chat)
        #expect(results.sections.first?.items.first === chat)
    }

    @Test("workspace-group results emits section and item deletes when archiving")
    func workspaceGroupControllerEmitsDeletesWhenArchiving() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats,
            sectionedBy: .workspaceGroup
        )
        var transactions = results.transactions.makeAsyncIterator()
        try await results.performFetch()
        _ = await transactions.next()

        let chat = try #require(results.items.first)
        let groupID = try #require(chat.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .archive)
        #expect(transaction.oldSnapshot.sectionIDs == [.workspaceGroup(groupID)])
        #expect(transaction.newSnapshot.sections.isEmpty)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .workspaceGroup(groupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(results.items.isEmpty)
        #expect(results.sections.isEmpty)
    }

    @Test("unsectioned results emits item and default-section deletes when deleting")
    func unsectionedControllerEmitsDeletesWhenDeleting() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-delete", name: "Delete")
        ]))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats
        )
        var transactions = results.transactions.makeAsyncIterator()
        try await results.performFetch()
        _ = await transactions.next()

        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.oldSnapshot.sectionIDs == [.default])
        #expect(transaction.newSnapshot.sections.isEmpty)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .default, index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(results.items.isEmpty)
        #expect(results.sections.isEmpty)
    }

    @Test("workspace results reloads stable rows after chat deletion")
    func workspaceControllerReloadsStableRowsAfterChatDeletion() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep"),
        ]))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspace>.workspaces
        )
        var transactions = results.transactions.makeAsyncIterator()
        try await results.performFetch()
        _ = await transactions.next()
        let workspace = try #require(results.items.first)
        let chat = try #require(workspace.chats.first { $0.id.rawValue == "thread-delete" })

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.sectionChanges.isEmpty)
        #expect(transaction.itemChanges == [
            .update(itemID: workspace.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(results.items.first === workspace)
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-keep"])
    }

    @Test("results does not emit moves for item shifts after deletion")
    func controllerDoesNotEmitMovesForItemShiftsAfterDeletion() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title)]
        ))
        var transactions = results.transactions.makeAsyncIterator()
        try await results.performFetch()
        _ = await transactions.next()
        let alpha = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await alpha.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.itemChanges == [
            .delete(itemID: alpha.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(results.items.map(\.title) == ["Beta"])
    }

    @Test("workspace-group results does not emit moves for section shifts after deletion")
    func workspaceGroupControllerDoesNotEmitMovesForSectionShiftsAfterDeletion() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
        ]))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspaceGroup
        )
        var transactions = results.transactions.makeAsyncIterator()
        try await results.performFetch()
        _ = await transactions.next()
        let alpha = try #require(results.items.first)
        let firstGroupID = try #require(alpha.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await alpha.delete()

        let transaction = try #require(await transactions.next())
        #expect(transaction.reason == .remove)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .workspaceGroup(firstGroupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: alpha.id, indexPath: .init(section: 0, item: 0)),
        ])
        #expect(results.items.map(\.title) == ["Beta"])
        #expect(results.sections.count == 1)
    }

    @Test("workspace-group results suppresses no-op moves in mixed refresh diffs")
    func workspaceGroupControllerSuppressesNoOpMovesInMixedRefreshDiffs() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let thirdRepo = try gitRepository(named: "Third")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)
        let thirdWorkspaceURL = try createDirectory("App", in: thirdRepo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
        ]))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspaceGroup
        )
        var transactions = results.transactions.makeAsyncIterator()
        try await results.performFetch()
        _ = await transactions.next()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })
        let beta = try #require(results.items.first { $0.id.rawValue == "thread-beta" })
        let firstGroupID = try #require(alpha.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-gamma", workspace: thirdWorkspaceURL, name: "Aardvark"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Zulu"),
        ]))

        try await results.refresh()

        let transaction = try #require(await transactions.next())
        let gamma = try #require(results.items.first { $0.id.rawValue == "thread-gamma" })
        let thirdGroupID = try #require(gamma.workspace?.workspaceGroup?.id)
        #expect(transaction.reason == .refresh)
        #expect(transaction.sectionChanges == [
            .insert(sectionID: .workspaceGroup(thirdGroupID), index: 0),
            .move(sectionID: .workspaceGroup(firstGroupID), from: 0, to: 2),
        ])
        #expect(transaction.itemChanges == [
            .insert(itemID: gamma.id, indexPath: .init(section: 0, item: 0)),
            .update(itemID: beta.id, indexPath: .init(section: 1, item: 0)),
            .update(itemID: alpha.id, indexPath: .init(section: 2, item: 0)),
        ])
    }

    @Test("workspace-group results emits delete and insert for non-surviving section moves")
    func workspaceGroupControllerEmitsDeleteInsertForNonSurvivingSectionMoves() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: firstWorkspaceURL, name: "Move"),
        ]))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspaceGroup
        )
        let recorder = FetchedResultsTransactionRecorder(stream: results.transactions)
        try await results.performFetch()
        #expect(await eventually { recorder.transactions.count == 1 })
        let chat = try #require(results.items.first)
        let firstGroupID = try #require(chat.workspace?.workspaceGroup?.id)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: secondWorkspaceURL,
            name: "Move"
        ))
        try await context.refresh(chat, includeTurns: false)

        #expect(await eventually { recorder.transactions.count >= 2 })
        let transaction = try #require(recorder.transactions.first { transaction in
            transaction.reason == .revalidate
                && transaction.oldSnapshot.sectionIDs != transaction.newSnapshot.sectionIDs
        })
        let secondGroupID = try #require(chat.workspace?.workspaceGroup?.id)
        #expect(transaction.reason == .revalidate)
        #expect(transaction.sectionChanges == [
            .delete(sectionID: .workspaceGroup(firstGroupID), index: 0),
            .insert(sectionID: .workspaceGroup(secondGroupID), index: 0),
        ])
        #expect(transaction.itemChanges == [
            .delete(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
            .insert(itemID: chat.id, indexPath: .init(section: 0, item: 0)),
        ])
    }

    @Test("results suppresses unrelated revalidation transactions")
    func controllerSuppressesUnrelatedRevalidationTransactions() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try gitRepository(named: "First")
        let secondRepo = try gitRepository(named: "Second")
        let firstWorkspaceURL = try createDirectory("App", in: firstRepo)
        let secondWorkspaceURL = try createDirectory("App", in: secondRepo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: secondWorkspaceURL, name: "Beta"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title)]
        ))
        try await allResults.performFetch()
        let alpha = try #require(allResults.items.first { $0.id.rawValue == "thread-alpha" })
        let beta = try #require(allResults.items.first { $0.id.rawValue == "thread-beta" })
        let firstWorkspace = try #require(alpha.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: firstWorkspaceURL, name: "Alpha"),
        ]))
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.chats(
                in: firstWorkspace,
                sortBy: [CodexSortDescriptor(\.title)]
            )
        )
        let recorder = FetchedResultsTransactionRecorder(stream: results.transactions)
        try await results.performFetch()
        #expect(await eventually { recorder.transactions.count == 1 })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-beta"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-beta",
            workspace: secondWorkspaceURL,
            name: "Beta Updated"
        ))
        try await context.refresh(beta, includeTurns: false)

        #expect(await recorder.count(after: .milliseconds(20)) == 1)
        #expect(results.items.map(\.id) == [alpha.id])
    }

    @Test("results keeps update changes for items that move")
    func controllerKeepsUpdateChangesForItemsThatMove() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.title)]
        ))
        let recorder = FetchedResultsTransactionRecorder(stream: results.transactions)
        try await results.performFetch()
        #expect(await eventually { recorder.transactions.count == 1 })
        let alpha = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-alpha",
            name: "Zulu"
        ))
        try await context.refresh(alpha, includeTurns: false)

        #expect(await eventually { recorder.transactions.count >= 2 })
        let transaction = try #require(recorder.transactions.first { transaction in
            transaction.reason == .revalidate
                && transaction.itemChanges.contains {
                    if case .move(let itemID, _, _) = $0 {
                        return itemID == alpha.id
                    }
                    return false
                }
        })
        #expect(transaction.reason == .revalidate)
        #expect(results.items.map(\.title) == ["Beta", "Zulu"])
        #expect(transaction.itemChanges.contains(
            .move(
                itemID: alpha.id,
                from: .init(section: 0, item: 0),
                to: .init(section: 0, item: 1)
            )
        ))
        #expect(transaction.itemChanges.contains(
            .update(itemID: alpha.id, indexPath: .init(section: 0, item: 1))
        ))
    }

    @Test("fetched chat exposes app-server thread status and recency")
    func fetchedChatExposesThreadStatusAndRecency() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let recencyAt = Date(timeIntervalSince1970: 1234)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-active",
                name: "Active",
                recencyAt: recencyAt,
                status: .active(activeFlags: [.waitingOnUserInput])
            )
        ]))

        let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)
        let chat = try #require(chats.first)

        #expect(chat.recencyAt == recencyAt)
        #expect(chat.status == .active(activeFlags: [.waitingOnUserInput]))
    }

    @Test("fetched results apply configured fetch offset on initial fetch")
    func fetchedResultsApplyConfiguredFetchOffsetOnInitialFetch() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-a", name: "A"),
            .init(id: "thread-b", name: "B"),
        ]))

        let request = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1,
            fetchOffset: 1
        )
        let results = context.fetchedResults(for: request)
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["B"])
    }

    @Test("mutable fetch offsets preserve configured optional values")
    func mutableFetchOffsetsPreserveConfiguredOptionalValues() {
        var descriptor = CodexFetchDescriptor<CodexChat>(fetchOffset: 1)
        descriptor.fetchOffset = nil

        var request = CodexFetchDescriptor<CodexChat>(fetchOffset: 1)
        request.fetchOffset = nil

        #expect(descriptor.fetchOffset == nil)
        #expect(request.fetchOffset == nil)
    }

    @Test("offset chat fetches do not preserve live chats omitted from the page")
    func offsetChatFetchesDoNotPreserveLiveChatsOmittedFromPage() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let liveChat = context.model(for: CodexThreadID(rawValue: "thread-a"))
        liveChat.apply(
            .init(
                id: "thread-a",
                name: "A",
                status: .active(activeFlags: [])
            ),
            workspace: nil
        )

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-b", name: "B"),
            .init(id: "thread-c", name: "C"),
        ]))

        let request = CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1,
            fetchOffset: 1
        )
        let results = context.fetchedResults(for: request)
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["C"])
    }

    @Test("name-sorted chat pages are sliced after local sorting")
    func nameSortedChatPagesAreSlicedAfterLocalSorting() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .currentV2,
                threads: [.init(id: "thread-zulu", workspace: workspace, name: "Zulu")],
                nextCursor: "server-next"
            ))
        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .currentV2, threads: [.init(id: "thread-alpha", workspace: workspace, name: "Alpha")]))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        let fetchedWorkspace = try #require(results.items.first?.workspace)
        #expect(results.items.map(\.title) == ["Alpha"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])
        #expect(results.nextCursor?.isEmpty == false)

        let initialRequests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(initialRequests.count == 3)
        let firstParams = try #require(initialRequests.first).decodeParams(ThreadListParams.self)
        let secondParams = try #require(initialRequests.dropFirst().first)
            .decodeParams(ThreadListParams.self)
        let partitionParams = try #require(initialRequests.last)
            .decodeParams(ThreadListParams.self)
        #expect(firstParams.cursor == nil)
        #expect(firstParams.limit == nil)
        #expect(secondParams.cursor == "server-next")
        #expect(secondParams.limit == nil)
        #expect(partitionParams.cursor == nil)
        #expect(partitionParams.sourceKinds != nil)

        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .currentV2,
                threads: [.init(id: "thread-zulu", workspace: workspace, name: "Zulu")],
                nextCursor: "server-next"
            ))
        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .currentV2, threads: [.init(id: "thread-alpha", workspace: workspace, name: "Alpha")]))

        try await results.loadNextPage()

        #expect(results.items.map(\.title) == ["Alpha", "Zulu"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])
        #expect(results.nextCursor == nil)
    }

    @Test("appended local pages preserve the loaded window backwards cursor")
    func appendedLocalPagesPreserveLoadedWindowBackwardsCursor() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()
        let page = try DataKitTestThreadPage(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ])

        try await runtime.transport.enqueueUserVisibleThreadList(page)
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.title) == ["Alpha"])
        #expect(results.backwardsCursor == nil)

        try await runtime.transport.enqueueUserVisibleThreadList(page)
        try await results.loadNextPage()

        #expect(results.items.map(\.title) == ["Alpha", "Beta"])
        #expect(results.backwardsCursor == nil)
    }

    @Test("appended local pages preserve live chats omitted from complete relationships")
    func appendedLocalPagesPreserveLiveChatsOmittedFromCompleteRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-running",
                workspace: workspace,
                name: "A Running",
                status: .active(activeFlags: [])
            ),
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.id.rawValue) == ["thread-running"])
        #expect(results.nextCursor != nil)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue).contains("thread-running"))
        #expect(results.items.first?.id.rawValue == "thread-running")
    }

    @Test("fetched-results loads serialize and commit one cursor generation")
    func fetchedResultsLoadsSerializeCursorGenerations() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let appendGate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a", name: "A")],
            nextCursor: "page-2"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a2", name: "A2")]
        ))
        await runtime.transport.holdNext(method: "thread/list", gate: appendGate)
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-b", name: "B")]
        ))

        let append = Task { @MainActor in
            try await results.loadNextPage()
        }
        await runtime.transport.waitForRequest(method: "thread/list", count: 2)

        let refresh = Task { @MainActor in
            try await results.refresh()
        }
        await results.waitUntilPendingLoad()
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)

        await appendGate.open()
        try await append.value
        try await refresh.value

        #expect(results.items.map(\.id.rawValue) == ["thread-b"])
        #expect(results.nextCursor == nil)
        #expect(results.phase == .loaded)
    }

    @Test("concurrent perform-fetch calls derive reasons after serialization")
    func concurrentPerformFetchCallsDeriveSerializedReasons() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstFetchGate = CodexAppServerTestGate()
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        let recorder = FetchedResultsTransactionRecorder(stream: results.transactions)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-a", name: "A")
        ]))
        await runtime.transport.holdNext(method: "thread/list", gate: firstFetchGate)
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-b", name: "B")
        ]))

        let firstFetch = Task { @MainActor in
            try await results.performFetch()
        }
        await runtime.transport.waitForRequest(method: "thread/list", count: 1)
        let secondFetch = Task { @MainActor in
            try await results.performFetch()
        }
        await results.waitUntilPendingLoad()

        await firstFetchGate.open()
        try await firstFetch.value
        try await secondFetch.value
        #expect(await eventually { recorder.transactions.count == 2 })
        #expect(recorder.transactions.map(\.reason) == [.initialFetch, .refresh])
        #expect(results.items.map(\.id.rawValue) == ["thread-b"])
    }

    @Test("queued fetched-results load cancellation removes its intent")
    func queuedFetchedResultsCancellationRemovesIntent() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let appendGate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a", name: "A")],
            nextCursor: "page-2"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a2", name: "A2")]
        ))
        await runtime.transport.holdNext(method: "thread/list", gate: appendGate)
        let append = Task { @MainActor in
            try await results.loadNextPage()
        }
        await runtime.transport.waitForRequest(method: "thread/list", count: 2)

        let refresh = Task { @MainActor in
            try await results.refresh()
        }
        await results.waitUntilPendingLoad()
        refresh.cancel()
        do {
            try await refresh.value
            Issue.record("Expected queued refresh cancellation")
        } catch is CancellationError {
        }

        await appendGate.open()
        try await append.value

        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
        #expect(results.items.map(\.id.rawValue) == ["thread-a", "thread-a2"])
        #expect(results.phase == .loaded)
    }

    @Test("in-flight cancellation discards a cancellation-unaware staged page")
    func inFlightFetchedResultsCancellationDiscardsStagedPage() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let appendGate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a", name: "A")],
            nextCursor: "page-2"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-b", name: "B")]
        ))
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/list",
            gate: appendGate
        )
        let append = Task { @MainActor in
            try await results.loadNextPage()
        }
        await runtime.transport.waitForRequest(method: "thread/list", count: 2)

        append.cancel()
        await appendGate.open()
        do {
            try await append.value
            Issue.record("Expected in-flight load cancellation")
        } catch is CancellationError {
        }

        #expect(results.items.map(\.id.rawValue) == ["thread-a"])
        #expect(results.nextCursor == "page-2")
        #expect(results.phase == .loaded)
    }

    @Test("fetched-results refresh preserves its loaded page window")
    func fetchedResultsRefreshPreservesLoadedWindow() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a1", name: "A1")],
            nextCursor: "page-2"
        ))
        try await results.performFetch()
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a2", name: "A2")],
            nextCursor: "page-3"
        ))
        try await results.loadNextPage()
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-a3", name: "A3")]
        ))
        try await results.loadNextPage()
        #expect(results.items.map(\.id.rawValue) == ["thread-a1", "thread-a2", "thread-a3"])

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-b1", name: "B1")],
            nextCursor: "page-2"
        ))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-b2", name: "B2")],
            nextCursor: "page-3"
        ))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-b3", name: "B3")]
        ))

        try await results.refresh()

        #expect(results.items.map(\.id.rawValue) == ["thread-b1", "thread-b2", "thread-b3"])
        #expect(results.nextCursor == nil)
    }

    @Test("local paged chat load reconciles stale loaded items")
    func localPagedChatLoadReconcilesStaleLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.title) == ["Alpha"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.title) == ["Beta", "Zulu"])
    }

    @Test("name-sorted chat pages prune stale workspace relationships from full local results")
    func nameSortedChatPagesPruneStaleWorkspaceRelationshipsFromFullLocalResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)
        let staleChat = context.model(for: CodexThreadID(rawValue: "thread-zulu"))
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
        ]))
        try await results.refresh()

        #expect(results.items.map(\.title) == ["Alpha"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Beta"])
        #expect(staleChat.workspace == nil)
    }

    @Test("one-shot name-sorted fetches prune stale workspace relationships from full local results")
    func oneShotNameSortedFetchesPruneStaleWorkspaceRelationshipsFromFullLocalResults()
        async throws
    {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
        ]))
        let allChats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        ))
        let fetchedWorkspace = try #require(allChats.first?.workspace)
        let staleChat = context.model(for: CodexThreadID(rawValue: "thread-zulu"))
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspace, name: "Beta"),
        ]))
        let firstPage = try await context.fetch(CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))

        #expect(firstPage.map(\.title) == ["Alpha"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Beta"])
        #expect(staleChat.workspace == nil)
    }

    @Test("one-shot chat fetch notifies registered results after pruning stale chats")
    func oneShotChatFetchNotifiesRegisteredResultsAfterPruningStaleChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()
        let initialPage = try DataKitTestThreadPage(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale")
        ])

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        ))
        try await chatResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let groupResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups
        )
        try await groupResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(chatResults.items.isEmpty)
        #expect(workspaceResults.items.isEmpty)
        #expect(workspaceResults.sections.isEmpty)
        #expect(groupResults.items.isEmpty)
        #expect(groupResults.sections.isEmpty)
    }

    @Test("thread list fetch inserts first-seen chats into registered scoped results")
    func threadListFetchInsertsFirstSeenChatsIntoRegisteredScopedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialPage = try DataKitTestThreadPage(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ])

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let initialChats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)
        let workspace = try #require(initialChats.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let scopedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.chats(
            in: workspace,
            sortBy: [CodexSortDescriptor(\.name)]
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await scopedResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing"),
            .init(id: "thread-new", workspace: workspaceURL, name: "New"),
        ]))
        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(scopedResults.items.map(\.id.rawValue) == ["thread-existing", "thread-new"])
        #expect(scopedResults.sections.count == 1)
        #expect(scopedResults.sections.first?.items.map(\.id.rawValue) == [
            "thread-existing",
            "thread-new",
        ])
    }

    @Test("workspace-scoped chat fetch applies scoped workspace when snapshots omit cwd")
    func workspaceScopedChatFetchAppliesScopedWorkspaceWhenSnapshotsOmitCWD() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [
                {
                  "id": "thread-new",
                  "name": "New",
                  "source": "cli"
                }
              ]
            }
            """
        )
        let scopedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.chats(
            in: workspace
        ))
        try await scopedResults.performFetch()

        let chat = try #require(scopedResults.items.first)
        #expect(chat.workspace === workspace)
        #expect(workspace.chats.first === chat)
        #expect(chat.title == "New")
    }

    @Test("workspace and group fetches exclude explicit-null source candidates")
    func relationshipFetchesExcludeKnownNullSourceCandidates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let response =
            """
            {
              "data": [{
                "id": "thread-relationship-null",
                "cwd": "\(workspaceURL.path)",
                "name": "Known null",
                "source": null
              }],
              "nextCursor": null
            }
            """

        try await runtime.transport.enqueueUserVisibleThreadListJSON(response)
        let workspaceResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspace>.workspaces
        )
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadListJSON(response)
        let groupResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups
        )
        try await groupResults.performFetch()

        #expect(workspaceResults.items.isEmpty)
        #expect(groupResults.items.isEmpty)
        let chat = try #require(
            context.registeredModel(for: CodexThreadID("thread-relationship-null"))
        )
        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)
    }

    @Test("workspace refresh removes candidates whose source becomes explicit null")
    func workspaceRefreshExcludesKnownNullSourceCandidates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(id: "thread-refresh-null", workspace: workspaceURL, name: "Before")
            ]
        ))
        let workspaceResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspace>.workspaces
        )
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)
        let chat = try #require(workspace.chats.first)
        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)

        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [{
                "id": "thread-refresh-null",
                "cwd": "\(workspaceURL.path)",
                "name": "After",
                "source": null
              }],
              "nextCursor": null
            }
            """
        )
        try await context.refresh(workspace)

        #expect(workspace.chats.isEmpty)
        #expect(workspaceResults.items.isEmpty)
        #expect(context.registeredModel(for: chat.id) === chat)
        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)
    }

    @Test("group refresh removes candidates whose source becomes explicit null")
    func groupRefreshExcludesKnownNullSourceCandidates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        try await runtime.transport.enqueueUserVisibleThreadList(.init(
            profile: .partialDTO,
            threads: [
                .init(id: "thread-group-refresh-null", workspace: workspaceURL, name: "Before")
            ]
        ))
        let groupResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups
        )
        try await groupResults.performFetch()
        let group = try #require(groupResults.items.first)
        let chat = try #require(group.workspaces.first?.chats.first)

        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [{
                "id": "thread-group-refresh-null",
                "cwd": "\(workspaceURL.path)",
                "name": "After",
                "source": null
              }],
              "nextCursor": null
            }
            """
        )
        try await context.refresh(group)

        #expect(group.workspaces.isEmpty)
        #expect(groupResults.items.isEmpty)
        #expect(context.registeredModel(for: chat.id) === chat)
        #expect(chat.source == nil)
        #expect(chat.sourceKind == nil)
    }

    @Test("thread list fetch inserts first-seen parents into registered results")
    func threadListFetchInsertsFirstSeenParentsIntoRegisteredResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let groupResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-new", workspace: workspaceURL, name: "New")
        ]))
        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        let workspace = try #require(workspaceResults.items.first)
        let group = try #require(groupResults.items.first)
        #expect(workspaceResults.items.count == 1)
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-new"])
        #expect(groupResults.items.count == 1)
        #expect(group.workspaces.contains { $0 === workspace })
        #expect(workspaceResults.sections.count == 1)
        #expect(groupResults.sections.count == 1)
    }

    @Test("workspace chats preserve fetched chat order")
    func workspaceChatsPreserveFetchedChatOrder() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-zulu", workspace: workspace, name: "Zulu"),
            .init(id: "thread-alpha", workspace: workspace, name: "Alpha"),
        ]))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        ))
        try await results.performFetch()

        let fetchedWorkspace = try #require(results.items.first?.workspace)
        #expect(results.items.map(\.title) == ["Alpha", "Zulu"])
        #expect(fetchedWorkspace.chats.map(\.title) == ["Alpha", "Zulu"])
    }

    @Test("filtered chat fetches keep previously loaded workspace chats")
    func filteredChatFetchesKeepPreviouslyLoadedWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-keep", workspace: workspace, name: "Keep"),
            .init(id: "thread-match", workspace: workspace, name: "Match"),
        ]))
        let allChats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)
        let fetchedWorkspace = try #require(allChats.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-match", workspace: workspace, name: "Match")
        ]))
        let filteredResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: searchChatPredicate("Match")
        ))
        try await filteredResults.performFetch()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-keep", "thread-match"])
    }

    @Test("empty search terms behave like unfiltered chat fetches")
    func emptySearchTermsBehaveLikeUnfilteredChatFetches() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>())
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let firstParams = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(firstParams.searchTerm == nil)
        #expect(results.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("empty source-kind filters behave like unfiltered chat fetches")
    func emptySourceKindFiltersBehaveLikeUnfilteredChatFetches() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>())
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let firstParams = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(firstParams.sourceKinds == nil)
        #expect(results.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("workspace fetches prune chats omitted from the refreshed active list")
    func workspaceFetchesPruneChatsOmittedFromRefreshedActiveList() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-keep", workspace: workspace, name: "Keep"),
            .init(id: "thread-match", workspace: workspace, name: "Match"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await allResults.performFetch()
        let fetchedWorkspace = try #require(allResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-match", workspace: workspace, name: "Match")
        ]))
        let filteredResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await filteredResults.performFetch()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-match"])
    }

    @Test("unfiltered chat refresh prunes stale workspace chats")
    func unfilteredChatRefreshPrunesStaleWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)
        let staleChat = try #require(results.items.first { $0.id.rawValue == "thread-stale" })

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
        #expect(staleChat.workspace == nil)
    }

    @Test("workspace fetch preserves live-only workspace omitted from refresh")
    func workspaceFetchPreservesLiveOnlyWorkspaceOmittedFromRefresh() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-running",
                workspace: workspace,
                name: "Running",
                status: .active(activeFlags: [])
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first)
        let runningChat = try #require(fetchedWorkspace.chats.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await results.refresh()

        #expect(results.items.map(\.url) == [workspace])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-running"])
        #expect(runningChat.workspace === fetchedWorkspace)
    }

    @Test("workspace group fetch preserves live-only workspace omitted from refresh")
    func workspaceGroupFetchPreservesLiveOnlyWorkspaceOmittedFromRefresh() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository(named: "LiveOnly")
        let workspace = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-running",
                workspace: workspace,
                name: "Running",
                status: .active(activeFlags: [])
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let group = try #require(results.items.first)
        let fetchedWorkspace = try #require(group.workspaces.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await results.refresh()

        #expect(results.items.map(\.id) == [group.id])
        #expect(group.workspaces.map(\.url) == [workspace])
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-running"])
    }

    @Test("workspace fetch excludes live-only relationships when pending changes are disabled")
    func workspaceFetchExcludesLiveOnlyRelationshipsWhenPendingChangesAreDisabled() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository(named: "NoPending")
        let workspace = try createDirectory("App", in: repo)
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-running",
                workspace: workspace,
                name: "Running",
                status: .active(activeFlags: [])
            )
        ]))
        let seedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await seedResults.performFetch()
        let runningChat = try #require(
            context.registeredModel(for: CodexThreadID(rawValue: "thread-running"))
        )

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>(
            includeContextChanges: false
        ))
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let groupResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>(
            includeContextChanges: false
        ))
        try await groupResults.performFetch()

        #expect(workspaceResults.items.isEmpty)
        #expect(groupResults.items.isEmpty)
        #expect(runningChat.workspace?.url == workspace)
    }

    @Test("started review prepared threads do not preserve stale fetched chat rows")
    func startedReviewPreparedThreadsDoNotPreserveStaleFetchedChatRows() async throws {
        let workspace = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-review",
                state: .inProgress,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspace,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let chat = started.chat
        #expect(chat.workspace != nil)
        #expect(chat.source == .subAgent(.review))
        #expect(chat.sourceKind == .subAgentReview)

        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-review",
            workspace: workspace,
            status: .idle
        ))
        try await context.refresh(chat, includeTurns: false)
        #expect(chat.status == .idle)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()

        #expect(results.items.isEmpty)
        #expect(chat.workspace == nil)
    }

    @Test("archived false chat refresh prunes stale workspace chats")
    func archivedFalseChatRefreshPrunesStaleWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(false),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("chat refresh removes chat from previous workspace when reparented")
    func chatRefreshRemovesChatFromPreviousWorkspaceWhenReparented() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let oldWorkspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: newWorkspaceURL,
            name: "Move"
        ))
        try await context.refresh(chat, includeTurns: false)

        #expect(oldWorkspace.chats.isEmpty)
        #expect(chat.workspace?.url == newWorkspaceURL)
        #expect(chat.workspace?.chats.first === chat)
    }

    @Test("chat refresh revalidates active fetched results")
    func chatRefreshRevalidatesActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await allResults.performFetch()
        let chat = try #require(allResults.items.first)
        let oldWorkspace = try #require(chat.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let oldWorkspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.chats(
            in: oldWorkspace
        ))
        try await oldWorkspaceResults.performFetch()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: newWorkspaceURL,
            name: "Move"
        ))
        try await context.refresh(chat, includeTurns: false)

        #expect(oldWorkspaceResults.items.isEmpty)
        #expect(allResults.items.first === chat)
    }

    @Test("thread list fetch revalidates workspace scoped fetched results")
    func threadListFetchRevalidatesWorkspaceScopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await allResults.performFetch()
        let chat = try #require(allResults.items.first)
        let oldWorkspace = try #require(chat.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let oldWorkspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.chats(
            in: oldWorkspace
        ))
        try await oldWorkspaceResults.performFetch()
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: oldWorkspaceURL, name: "Move")
        ]))
        let sectionedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await sectionedResults.performFetch()
        let oldWorkspaceSectionID = CodexFetchSectionID.workspace(.init(rawValue: oldWorkspaceURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path))
        #expect(sectionedResults.sections.first?.id == oldWorkspaceSectionID)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: newWorkspaceURL, name: "Move")
        ]))
        let fetchedChats = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)
        let newWorkspaceSectionID = CodexFetchSectionID.workspace(.init(rawValue: newWorkspaceURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path))

        #expect(fetchedChats.first === chat)
        #expect(chat.workspace?.url == newWorkspaceURL)
        #expect(oldWorkspaceResults.items.isEmpty)
        #expect(sectionedResults.items.first === chat)
        #expect(sectionedResults.sections.first?.id == newWorkspaceSectionID)
    }

    @Test("thread list fetch revalidates metadata sorted fetched results")
    func threadListFetchRevalidatesMetadataSortedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialPage = try DataKitTestThreadPage(profile: .currentV2, threads: [
            .init(
                id: "thread-alpha",
                workspace: workspaceURL,
                name: "Alpha",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            .init(
                id: "thread-zulu",
                workspace: workspaceURL,
                name: "Zulu",
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
        ])

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let nameResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        ))
        try await nameResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let updatedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await updatedResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(initialPage)
        let sectionedNameResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await sectionedNameResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-alpha",
                workspace: workspaceURL,
                name: "Omega",
                updatedAt: Date(timeIntervalSince1970: 3_000)
            ),
            .init(
                id: "thread-zulu",
                workspace: workspaceURL,
                name: "Aardvark",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))
        _ = try await context.fetch(CodexFetchDescriptor<CodexChat>.recentChats)

        #expect(nameResults.items.map(\.title) == ["Aardvark", "Omega"])
        #expect(updatedResults.items.map(\.title) == ["Omega", "Aardvark"])
        #expect(sectionedNameResults.items.map(\.title) == ["Aardvark", "Omega"])
        #expect(sectionedNameResults.sections.first?.items.map(\.title) == ["Aardvark", "Omega"])
    }

    @Test("chat refresh preserves archived fetched result membership")
    func chatRefreshPreservesArchivedFetchedResultMembership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let chat = try #require(archivedResults.items.first)
        #expect(chat.isArchived)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let activeResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await activeResults.performFetch()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-archived"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-archived",
            workspace: workspaceURL,
            name: "Archived"
        ))
        try await context.refresh(chat, includeTurns: false)

        #expect(archivedResults.items.first === chat)
        #expect(activeResults.items.isEmpty)
    }

    @Test("archived fetch revalidates active fetched result membership")
    func archivedFetchRevalidatesActiveFetchedResultMembership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let activeResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await activeResults.performFetch()
        let chat = try #require(activeResults.items.first)
        #expect(chat.isArchived == false)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()

        #expect(chat.isArchived)
        #expect(activeResults.items.isEmpty)
        #expect(archivedResults.items.first === chat)
    }

    @Test("chat refresh preserves server-only filtered fetched results")
    func chatRefreshPreservesServerOnlyFilteredFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-source", workspace: workspaceURL, name: "Source")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-source",
            workspace: workspaceURL,
            name: "Source"
        ))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(
                id: "thread-source",
                workspace: workspaceURL,
                name: "Source"
            ).withSourceKind(.appServer)
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
    }

    @Test("source-filtered results preserve matching live chats omitted from thread list")
    func sourceFilteredResultsPreserveMatchingLiveChatsOmittedFromThreadList() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(
                id: "thread-live-source",
                workspace: workspaceURL,
                name: "Live source",
                status: .active(activeFlags: [])
            ).withSourceKind(.appServer)
        ]))
        let descriptor = CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer)
        )
        let results = context.fetchedResults(for: descriptor)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(context.preservedLiveChats(
            omittedFrom: [CodexChat](),
            descriptor: descriptor
        ).first === chat)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: []))
        try await results.refresh()

        #expect(results.items.first === chat)
    }

    @Test("default results do not preserve active memory-consolidation chats")
    func defaultResultsExcludeObservedActiveMemoryChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository(named: "Memory")
        let workspaceURL = try createDirectory("Internal", in: repo)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-memory",
                workspace: workspaceURL,
                name: "Memory",
                sourceKind: .subAgent,
                status: .active(activeFlags: [])
            )
        ]))
        let memoryResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.subAgent)
        ))
        try await memoryResults.performFetch()
        let memoryChat = try #require(memoryResults.items.first)
        let memoryWorkspace = try #require(memoryChat.workspace)
        let memoryGroup = try #require(memoryWorkspace.workspaceGroup)
        #expect(memoryChat.source == .subAgent(.memoryConsolidation))

        try await runtime.transport.enqueueUserVisibleThreadList(.init(threads: []))
        let defaultResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>.recentChats
        )
        try await defaultResults.performFetch()

        #expect(defaultResults.items.isEmpty)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(threads: []))
        let groupResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups
        )
        try await groupResults.performFetch()

        #expect(groupResults.items.isEmpty)
        #expect(memoryWorkspace.chats.isEmpty)
        #expect(memoryGroup.workspaces.isEmpty)
        #expect(memoryResults.items.first === memoryChat)
    }

    @Test("default empty sorting orders preserved live chats by creation date")
    func defaultEmptySortOrdersPreservedLiveChatsByCreationDate() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let newerDate = Date(timeIntervalSince1970: 200)
        let olderDate = Date(timeIntervalSince1970: 100)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-active-newer",
                workspace: workspaceURL,
                name: "Newer",
                sourceKind: .appServer,
                createdAt: newerDate,
                status: .active(activeFlags: [])
            )
        ]))
        let sourceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.appServer)
        ))
        try await sourceResults.performFetch()
        let activeChat = try #require(sourceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-older",
                workspace: workspaceURL,
                name: "Older",
                sourceKind: .cli,
                createdAt: olderDate
            )
        ]))
        let descriptor = CodexFetchDescriptor<CodexChat>()
        let defaultResults = context.fetchedResults(for: descriptor)
        try await defaultResults.performFetch()

        #expect(defaultResults.items.map(\.id.rawValue) == [
            "thread-active-newer",
            "thread-older",
        ])
        #expect(context.sortedItems(
            Array(defaultResults.items.reversed()),
            for: descriptor
        ).map(\.id.rawValue) == [
            "thread-active-newer",
            "thread-older",
        ])
        #expect(defaultResults.items.first === activeChat)
    }

    @Test("chat refresh rebuilds server-only filtered sections")
    func chatRefreshRebuildsServerOnlyFilteredSections() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let oldWorkspaceURL = temporaryDirectory()
        let newWorkspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-source", workspace: oldWorkspaceURL, name: "Source")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.appServer])
        ), sectionedBy: CodexSectionDescriptor(\.workspaceID))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(
            results.sections.first?.id == .workspace(.init(rawValue: oldWorkspaceURL.standardizedFileURL
                .resolvingSymlinksInPath().path))
        )

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-source",
            workspace: newWorkspaceURL,
            name: "Source"
        ))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(
                id: "thread-source",
                workspace: newWorkspaceURL,
                name: "Source"
            ).withSourceKind(.appServer)
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
        #expect(
            results.sections.first?.id == .workspace(.init(rawValue: newWorkspaceURL.standardizedFileURL
                .resolvingSymlinksInPath().path))
        )
    }

    @Test("recency sort applies a same-direction stable thread-ID tie-break")
    func recencySortAppliesStableThreadIDTieBreak() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-server-first",
                name: "Server first",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            .init(
                id: "thread-server-second",
                name: "Server second",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-server-second", "thread-server-first"])
    }

    @Test("secondary descriptors are applied after primary recency values tie")
    func secondaryDescriptorsApplyAfterPrimaryRecencyTies() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-zulu", name: "Zulu"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse), CodexSortDescriptor(\.name)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["Alpha", "Zulu"])
    }

    @Test("secondary descriptors use exhaustive stable-cursor enumeration before local paging")
    func secondaryDescriptorsUseExhaustiveEnumerationBeforeLocalPaging() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .currentV2,
                threads: [.init(id: "thread-zulu", name: "Zulu")],
                nextCursor: "server-next"
            ))
        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(
                profile: .currentV2,
                threads: [.init(id: "thread-alpha", name: "Alpha")]
            ))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse), CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let params = try #require(requests.first).decodeParams(ThreadListParams.self)
        #expect(requests.count == 3)
        #expect(params.limit == nil)
        #expect(params.sortKey == "recency_at")
        #expect(results.nextCursor == context.localCursor(for: 1))
        #expect(results.items.map(\.title) == ["Alpha"])
    }

    @Test("default chat ordering follows the app-server after a model refresh")
    func defaultChatOrderingFollowsAppServerAfterModelRefresh() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>())
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-alpha", name: "Alpha"))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-beta", name: "Beta"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))
        try await context.refresh(alpha, includeTurns: false)

        #expect(results.items.map(\.id.rawValue) == ["thread-beta", "thread-alpha"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 4)
    }

    @Test("non-recency sort descriptors still apply when recency is present")
    func nonRecencySortDescriptorsStillApplyWhenRecencyIsPresent() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-zulu", name: "Zulu"),
            .init(id: "thread-alpha", name: "Alpha"),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(sortBy: [CodexSortDescriptor(\.name), CodexSortDescriptor(\.recencyAt, order: .reverse)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.title) == ["Alpha", "Zulu"])
    }

    @Test("reverse date sorts keep missing dates behind dated chats")
    func reverseDateSortsKeepMissingDatesBehindDatedChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-undated", name: "Undated"),
            .init(
                id: "thread-dated",
                name: "Dated",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)])
        )
        try await results.performFetch()

        #expect(results.items.map(\.id.rawValue) == ["thread-dated", "thread-undated"])
    }

    @Test("workspace and chat fetches can be sectioned by relationship aliases")
    func fetchesSupportWorkspaceSections() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        let page = try DataKitTestThreadPage(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App chat"),
            .init(id: "thread-tools", workspace: tools, name: "Tools chat"),
        ])
        try await runtime.transport.enqueueUserVisibleThreadList(page)

        #expect(CodexSectionDescriptor<CodexWorkspace>.workspaceGroup == .init(\.workspaceGroupID))
        #expect(CodexSectionDescriptor<CodexChat>.workspaceGroup == .init(\.workspaceGroupID))
        #expect(CodexSectionDescriptor<CodexChat>.workspace == .init(\.workspaceID))

        let workspaceResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspace>.workspaces(),
            sectionedBy: .workspaceGroup
        )
        try await workspaceResults.performFetch()

        let workspaceSection = try #require(workspaceResults.sections.first)
        #expect(workspaceResults.items.map(\.name).sorted() == ["App", "Tools"])
        #expect(workspaceResults.sections.count == 1)
        #expect(workspaceSection.title == repo.lastPathComponent)
        #expect(workspaceSection.items.map(\.name).sorted() == ["App", "Tools"])
        let workspaceGroup = try #require(workspaceSection.workspaceGroup)
        #expect(workspaceSection.workspaceGroupID == workspaceGroup.id)
        #expect(workspaceSection.workspaces.map(\.id) == workspaceSection.items.map(\.id))

        try await runtime.transport.enqueueUserVisibleThreadList(page)

        let chatResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: .workspace
        )
        try await chatResults.performFetch()

        #expect(chatResults.sections.compactMap(\.title).sorted() == ["App", "Tools"])
        #expect(
            chatResults.items.map(\.workspace?.workspaceGroup?.id).allSatisfy {
                $0 == workspaceResults.items.first?.workspaceGroup?.id
            })
        let appSection = try #require(chatResults.sections.first { $0.title == "App" })
        let appWorkspace = try #require(appSection.workspaces.first)
        #expect(appSection.workspaceID == appWorkspace.id)
        #expect(appSection.workspaceGroup === workspaceGroup)
        #expect(appSection.workspaces.map(\.name) == ["App"])
        #expect(appSection.uncategorizedChats.isEmpty)
        #expect(appSection.chats(in: appWorkspace.id).map(\.id.rawValue) == ["thread-app"])
        #expect(appSection.chat(id: "thread-app")?.id.rawValue == "thread-app")
        #expect(appSection.chat(id: "thread-tools")?.id.rawValue == nil)
    }

    @Test("chat section exposes uncategorized chats")
    func chatSectionExposesUncategorizedChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(id: "thread-app", workspace: workspaceURL, name: "App", sourceKind: .cli),
            .init(id: "thread-uncategorized", name: "Uncategorized", sourceKind: .cli),
        ]))

        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                sortBy: [CodexSortDescriptor(\.title)]
            ),
            sectionedBy: CodexSectionDescriptor(\.workspaceID)
        )
        try await results.performFetch()

        let section = try #require(results.sections.first { $0.uncategorizedChats.isEmpty == false })
        #expect(section.workspaceGroupID == nil)
        #expect(section.workspaceID == nil)
        #expect(section.workspaceGroup == nil)
        #expect(section.workspaces.isEmpty)
        #expect(section.uncategorizedChats.map(\.id.rawValue) == ["thread-uncategorized"])
        #expect(section.chats(in: .init(rawValue: workspaceURL.standardizedFileURL.path)).isEmpty)
        #expect(section.chat(id: "thread-uncategorized")?.id.rawValue == "thread-uncategorized")
    }

    @Test("workspace fetch pagination is applied after workspace deduplication")
    func workspaceFetchPaginationIsAppliedAfterWorkspaceDeduplication() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstWorkspace = temporaryDirectory()
        let secondWorkspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-first-a", workspace: firstWorkspace, name: "First A"),
                .init(id: "thread-first-b", workspace: firstWorkspace, name: "First B"),
            ],
            nextCursor: "server-next"
        ))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-second", workspace: secondWorkspace, name: "Second")
            ]
        ))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await results.performFetch()

        #expect(Set(results.items.map(\.url)) == Set([firstWorkspace, secondWorkspace]))
        #expect(results.nextCursor == nil)

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(requests.count == 3)
    }

    @Test("local paged workspace load reconciles stale loaded items")
    func localPagedWorkspaceLoadReconcilesStaleLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstWorkspace = temporaryDirectory().appendingPathComponent("Alpha", isDirectory: true)
        let secondWorkspace = temporaryDirectory().appendingPathComponent("Beta", isDirectory: true)
        let thirdWorkspace = temporaryDirectory().appendingPathComponent("Zulu", isDirectory: true)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: firstWorkspace, name: "Alpha"),
            .init(id: "thread-zulu", workspace: thirdWorkspace, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.name) == ["Alpha"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-beta", workspace: secondWorkspace, name: "Beta"),
            .init(id: "thread-zulu", workspace: thirdWorkspace, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.name) == ["Beta", "Zulu"])
    }

    @Test("workspace regrouping removes it from previous group")
    func workspaceRegroupingRemovesItFromPreviousGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await results.performFetch()
        let workspace = try #require(results.items.first)
        let previousGroup = try #require(workspace.workspaceGroup)

        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        try await results.performFetch()
        let currentGroup = try #require(workspace.workspaceGroup)

        #expect(currentGroup !== previousGroup)
        #expect(previousGroup.workspaces.contains { $0 === workspace } == false)
        #expect(currentGroup.workspaces.contains { $0 === workspace })
    }

    @Test("group refresh preserves workspace contents when it moves groups")
    func groupRefreshPreservesWorkspaceContentsWhenItMovesGroups() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let previousGroup = try #require(results.items.first)
        let workspace = try #require(previousGroup.workspaces.first)
        let chat = try #require(workspace.chats.first)

        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-regroup", workspace: workspaceURL, name: "Regroup")
        ]))
        try await context.refresh(previousGroup)

        let currentGroup = try #require(workspace.workspaceGroup)
        #expect(currentGroup !== previousGroup)
        #expect(previousGroup.workspaces.isEmpty)
        #expect(currentGroup.workspaces.contains { $0 === workspace })
        #expect(workspace.chats.first === chat)
        #expect(chat.workspace === workspace)
        #expect(results.items.map(\.id) == [currentGroup.id])
    }

    @Test("group refresh prunes stale chats when a workspace moves groups")
    func groupRefreshPrunesStaleChatsWhenWorkspaceMovesGroups() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let previousGroup = try #require(results.items.first)
        let workspace = try #require(previousGroup.workspaces.first)
        let staleChat = try #require(workspace.chats.first { $0.id.rawValue == "thread-stale" })
        let keepChat = try #require(workspace.chats.first { $0.id.rawValue == "thread-keep" })

        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep")
        ]))
        try await context.refresh(previousGroup)

        let currentGroup = try #require(workspace.workspaceGroup)
        #expect(currentGroup !== previousGroup)
        #expect(previousGroup.workspaces.isEmpty)
        #expect(currentGroup.workspaces.contains { $0 === workspace })
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-keep"])
        #expect(keepChat.workspace === workspace)
        #expect(staleChat.workspace == nil)
        #expect(results.items.map(\.id) == [currentGroup.id])
    }

    @Test("paged workspace fetches prune stale workspace chats")
    func pagedWorkspaceFetchesPruneStaleWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let fetchedWorkspace = try #require(results.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await results.refresh()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("paged workspace revalidation backfills when new parent cannot be inserted")
    func pagedWorkspaceRevalidationBackfillsWhenNewParentCannotBeInserted() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let backfill = try createDirectory("Backfill", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: app, name: "Move"),
            .init(id: "thread-backfill", workspace: backfill, name: "Backfill"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first?.chats.first)
        #expect(results.items.map(\.url) == [app])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: tools,
            name: "Move"
        ))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-backfill", workspace: backfill, name: "Backfill"),
            .init(id: "thread-move", workspace: tools, name: "Move"),
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.map(\.url) == [backfill])
    }

    @Test("paged workspace revalidation refreshes when a new parent precedes visible items")
    func pagedWorkspaceRevalidationRefreshesWhenNewParentPrecedesVisibleItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let incoming = try createDirectory("AIncoming", in: repo)
        let visible = try createDirectory("BVisible", in: repo)
        let moving = try createDirectory("CMove", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
            .init(id: "thread-move", workspace: moving, name: "Move"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-move"))
        #expect(chat.workspace?.url == moving)
        #expect(results.items.map(\.url) == [visible])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: incoming,
            name: "Move"
        ))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: incoming, name: "Move"),
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.map(\.url) == [incoming])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 4)
    }

    @Test("paged group revalidation refreshes when a new parent precedes visible items")
    func pagedGroupRevalidationRefreshesWhenNewParentPrecedesVisibleItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let incomingRepo = try gitRepository(named: "AIncoming")
        let visibleRepo = try gitRepository(named: "BVisible")
        let movingRepo = try gitRepository(named: "CMove")
        let incoming = try createDirectory("App", in: incomingRepo)
        let visible = try createDirectory("App", in: visibleRepo)
        let moving = try createDirectory("App", in: movingRepo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
            .init(id: "thread-move", workspace: moving, name: "Move"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-move"))
        #expect(chat.workspace?.url == moving)
        #expect(results.items.map(\.name) == ["BVisible"])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: incoming,
            name: "Move"
        ))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: incoming, name: "Move"),
            .init(id: "thread-visible", workspace: visible, name: "Visible"),
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.map(\.name) == ["AIncoming"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 4)
    }

    @Test("local paged group load reconciles stale loaded items")
    func localPagedGroupLoadReconcilesStaleLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let alphaRepo = try gitRepository(named: "Alpha")
        let betaRepo = try gitRepository(named: "Beta")
        let zuluRepo = try gitRepository(named: "Zulu")
        let alpha = try createDirectory("App", in: alphaRepo)
        let beta = try createDirectory("App", in: betaRepo)
        let zulu = try createDirectory("App", in: zuluRepo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: alpha, name: "Alpha"),
            .init(id: "thread-zulu", workspace: zulu, name: "Zulu"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        #expect(results.items.map(\.name) == ["Alpha"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-beta", workspace: beta, name: "Beta"),
            .init(id: "thread-zulu", workspace: zulu, name: "Zulu"),
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.name) == ["Beta", "Zulu"])
    }

    @Test("server paginated chat fetches preserve existing workspace relationships")
    func serverPaginatedChatFetchesPreserveExistingWorkspaceRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspace, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let fetchedWorkspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-new", workspace: workspace, name: "New")
            ],
            nextCursor: "server-next"
        ))
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\CodexChat.recencyAt, order: .reverse)]
        ))
        try await chatResults.performFetch()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-existing", "thread-new"])
    }

    @Test("server paginated chat appends preserve previously loaded items")
    func serverPaginatedChatAppendsPreservePreviouslyLoadedItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-existing", workspace: workspace, name: "Existing")
            ],
            nextCursor: "server-next"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\CodexChat.recencyAt, order: .reverse)]
        ))
        try await results.performFetch()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-new", workspace: workspace, name: "New")
        ]))
        try await results.loadNextPage()

        #expect(results.items.map(\.id.rawValue) == ["thread-existing", "thread-new"])
    }

    @Test("fully loaded paginated chat fetches prune stale workspace relationships")
    func fullyLoadedPaginatedChatFetchesPruneStaleWorkspaceRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspace, name: "Stale")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let fetchedWorkspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-new", workspace: workspace, name: "New")
            ],
            nextCursor: "server-next"
        ))
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\CodexChat.recencyAt, order: .reverse)]
        ))
        try await chatResults.performFetch()
        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == ["thread-stale", "thread-new"])

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspace, name: "Remaining")
        ]))
        try await chatResults.loadNextPage()

        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-new", "thread-remaining"])
    }

    @Test("active sync preserves archived workspace chats")
    func activeSyncPreservesArchivedWorkspaceChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", workspace: workspace, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let fetchedWorkspace = try #require(archivedResults.items.first?.workspace)
        #expect(fetchedWorkspace.chats.map(\.id.rawValue) == ["thread-archived"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-active", workspace: workspace, name: "Active")
        ]))
        let activeResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await activeResults.performFetch()

        #expect(activeResults.items.map(\.id.rawValue) == ["thread-active"])
        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == [
            "thread-archived",
            "thread-active",
        ])
        #expect(fetchedWorkspace.chats.contains {
            $0.id.rawValue == "thread-archived"
        } == true)
    }

    @Test("paged chat fetches append loaded workspace relationships")
    func pagedChatFetchesAppendLoadedWorkspaceRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspace = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-before", workspace: workspace, name: "Before"),
            .init(id: "thread-middle", workspace: workspace, name: "Middle"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await allResults.performFetch()
        let fetchedWorkspace = try #require(allResults.items.first?.workspace)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-middle", workspace: workspace, name: "Middle")
            ],
            nextCursor: "next"
        ))
        let cursorResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await cursorResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-after", workspace: workspace, name: "After")
        ]))
        try await cursorResults.loadNextPage()

        #expect(Set(fetchedWorkspace.chats.map(\.id.rawValue)) == [
            "thread-middle",
            "thread-after",
        ])
    }

    @Test("group refresh rebuilds workspaces from fetched result")
    func groupRefreshRebuildsWorkspacesFromFetchedResult() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await results.performFetch()
        let group = try #require(results.items.first)
        #expect(Set(group.workspaces.map(\.url)) == Set([app, tools]))

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        try await context.refresh(group)

        #expect(group.workspaces.map(\.url) == [app])
    }

    @Test("group refresh removes stale chats from active fetched results")
    func groupRefreshRemovesStaleChatsFromActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let group = try #require(chatResults.items.first?.workspace?.workspaceGroup)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        try await context.refresh(group)

        #expect(chatResults.items.map(\.id.rawValue) == ["thread-app"])
        #expect(group.workspaces.map(\.url) == [app])
    }

    @Test("group refresh preserves chats that moved to another group")
    func groupRefreshPreservesChatsThatMovedToAnotherGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let appRepo = try gitRepository(named: "AppRepo")
        let toolsRepo = try gitRepository(named: "ToolsRepo")
        let app = try createDirectory("App", in: appRepo)
        let tools = try createDirectory("Tools", in: toolsRepo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: app, name: "Move")
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let chat = try #require(chatResults.items.first)
        let group = try #require(chat.workspace?.workspaceGroup)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-move", workspace: tools, name: "Move")
        ]))
        try await context.refresh(group)

        #expect(chat.workspace?.url == tools)
        #expect(chatResults.items.first === chat)
        #expect(group.workspaces.isEmpty)
    }

    @Test("group refresh does not prune unrelated groups")
    func groupRefreshDoesNotPruneUnrelatedGroups() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let app = temporaryDirectory()
        let tools = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let appChat = try #require(chatResults.items.first { $0.id.rawValue == "thread-app" })
        let toolsChat = try #require(chatResults.items.first { $0.id.rawValue == "thread-tools" })
        let appGroup = try #require(appChat.workspace?.workspaceGroup)
        let toolsWorkspace = try #require(toolsChat.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        try await context.refresh(appGroup)

        #expect(toolsWorkspace.chats.first === toolsChat)
        #expect(toolsChat.workspace === toolsWorkspace)
        #expect(chatResults.items.contains { $0 === toolsChat })
    }

    @Test("group refresh preserves archived-only workspaces")
    func groupRefreshPreservesArchivedOnlyWorkspaces() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let archived = try createDirectory("Archived", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", workspace: archived, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let group = try #require(archivedResults.items.first?.workspace?.workspaceGroup)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-active", workspace: app, name: "Active")
        ]))
        try await context.refresh(group)

        #expect(Set(group.workspaces.map(\.url)) == Set([app, archived]))
    }

    @Test("active group fetch preserves archived-only workspaces")
    func activeGroupFetchPreservesArchivedOnlyWorkspaces() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let archived = try createDirectory("Archived", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", workspace: archived, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let group = try #require(archivedResults.items.first?.workspace?.workspaceGroup)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-active", workspace: app, name: "Active")
        ]))
        let activeResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await activeResults.performFetch()

        #expect(activeResults.items.first === group)
        #expect(Set(group.workspaces.map(\.url)) == Set([app, archived]))
    }

    @Test("workspace group fetches prune siblings omitted from the refreshed active list")
    func workspaceGroupFetchesPruneSiblingsOmittedFromRefreshedActiveList() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        let allGroups = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await allGroups.performFetch()
        let group = try #require(allGroups.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        let scopedGroups = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await scopedGroups.performFetch()

        #expect(scopedGroups.items.first === group)
        #expect(Set(group.workspaces.map(\.url)) == Set([app]))
    }

    @Test("workspace refresh revalidates scoped fetched results")
    func workspaceRefreshRevalidatesScopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let scopedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.chats(
            in: workspace
        ))
        try await scopedResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await context.refresh(workspace)

        #expect(scopedResults.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("workspace refresh inserts newly loaded scoped fetched results")
    func workspaceRefreshInsertsNewlyLoadedScopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let scopedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.chats(
            in: workspace
        ))
        try await scopedResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing"),
            .init(id: "thread-new", workspace: workspaceURL, name: "New"),
        ]))
        try await context.refresh(workspace)

        #expect(Set(scopedResults.items.map(\.id.rawValue)) == ["thread-existing", "thread-new"])
        #expect(Set(workspace.chats.map(\.id.rawValue)) == ["thread-existing", "thread-new"])
    }

    @Test("workspace refresh applies scoped workspace when snapshots omit cwd")
    func workspaceRefreshAppliesScopedWorkspaceWhenSnapshotsOmitCWD() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadListJSON(
            """
            {
              "data": [
                {
                  "id": "thread-new",
                  "name": "New"
                }
              ]
            }
            """
        )
        try await context.refresh(workspace)

        let chat = try #require(workspace.chats.first)
        #expect(chat.workspace === workspace)
        #expect(chat.id.rawValue == "thread-new")
        #expect(chat.title == "New")
    }

    @Test("workspace refresh revalidates unscoped fetched results")
    func workspaceRefreshRevalidatesUnscopedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await context.refresh(workspace)

        #expect(results.items.map(\.id.rawValue) == ["thread-remaining"])
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-remaining"])
    }

    @Test("workspace refresh preserves active chats omitted from server page")
    func workspaceRefreshPreservesActiveChatsOmittedFromServerPage() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-active-omitted",
                workspace: workspaceURL,
                name: "Active",
                status: .active(activeFlags: [])
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await context.refresh(workspace)

        #expect(results.items.first === chat)
        #expect(workspace.chats.first === chat)
        #expect(chat.workspace === workspace)
    }

    @Test("group refresh inserts newly loaded workspace fetched results")
    func groupRefreshInsertsNewlyLoadedWorkspaceFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let group = try #require(workspaceResults.items.first?.workspaceGroup)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-app", workspace: app, name: "App"),
            .init(id: "thread-tools", workspace: tools, name: "Tools"),
        ]))
        try await context.refresh(group)

        #expect(Set(workspaceResults.items.map(\.url)) == Set([app, tools]))
        #expect(Set(group.workspaces.map(\.url)) == Set([app, tools]))
    }

    @Test("group refresh preserves active chats omitted from server page")
    func groupRefreshPreservesActiveChatsOmittedFromServerPage() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-group-active-omitted",
                workspace: workspaceURL,
                name: "Active",
                status: .active(activeFlags: [])
            )
        ]))
        let groupResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()
        let group = try #require(groupResults.items.first)
        let workspace = try #require(group.workspaces.first)
        let chat = try #require(workspace.chats.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await context.refresh(group)

        #expect(groupResults.items.first === group)
        #expect(group.workspaces.first === workspace)
        #expect(workspace.chats.first === chat)
        #expect(chat.workspace === workspace)
    }

    @Test("workspace refresh preserves archived chats")
    func workspaceRefreshPreservesArchivedChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let workspace = try #require(archivedResults.items.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-active", workspace: workspaceURL, name: "Active")
        ]))
        try await context.refresh(workspace)

        #expect(Set(workspace.chats.map(\.id.rawValue)) == [
            "thread-archived",
            "thread-active",
        ])
    }

    @Test("workspace refresh revalidates unscoped filtered chat results")
    func workspaceRefreshRevalidatesUnscopedFilteredChatResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-match", workspace: workspaceURL, name: "Match")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: searchChatPredicate("Match")
        ))
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-match", workspace: workspaceURL, name: "Renamed")
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await context.refresh(workspace)

        #expect(results.items.isEmpty)
        #expect(workspace.chats.map(\.title) == ["Renamed"])
    }

    @Test("workspace refresh reloads search-filtered results from server")
    func workspaceRefreshReloadsSearchFilteredResultsFromServer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-search", workspace: workspaceURL, name: "needle")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: searchChatPredicate("needle")
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-search", workspace: workspaceURL, name: "needle")
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-search", workspace: workspaceURL, name: "needle")
        ]))
        try await context.refresh(workspace)

        #expect(results.items.first === chat)
        #expect(workspace.chats.first === chat)
    }

    @Test("workspace refresh preserves known chats when a source partition fails")
    func workspaceRefreshPreservesKnownChatsWhenSourcePartitionFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-remove", workspace: workspaceURL, name: "Remove")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: []))
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        do {
            try await context.refresh(workspace)
            Issue.record("Expected the second source partition to fail")
        } catch {
        }

        #expect(results.items.first === chat)
        #expect(workspace.chats.first === chat)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 3)
    }

    @Test("workspace refresh prunes empty workspace from group")
    func workspaceRefreshPrunesEmptyWorkspaceFromGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-stale", workspace: workspaceURL, name: "Stale")
        ]))
        let groupResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()
        let group = try #require(groupResults.items.first)
        let workspace = try #require(group.workspaces.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await context.refresh(workspace)

        #expect(workspace.chats.isEmpty)
        #expect(group.workspaces.isEmpty)
    }

    @Test("workspace refresh backfills paged chat results after removals")
    func workspaceRefreshBackfillsPagedChatResultsAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let backfillURL = temporaryDirectory()

        try await runtime.transport.enqueueBoundedUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-backfill", workspace: backfillURL, name: "Backfill")
        ]))
        try await context.refresh(workspace)

        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("group refresh backfills paged chat results after removals")
    func groupRefreshBackfillsPagedChatResultsAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let backfillURL = temporaryDirectory()

        try await runtime.transport.enqueueBoundedUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let group = try #require(results.items.first?.workspace?.workspaceGroup)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-backfill", workspace: backfillURL, name: "Backfill")
        ]))
        try await context.refresh(group)

        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("workspace results keep parents while matching chats remain")
    func workspaceResultsKeepParentsWhileMatchingChatsRemain() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-keep", workspace: workspaceURL, name: "Keep"),
            .init(id: "thread-match", workspace: workspaceURL, name: "Match"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await allResults.performFetch()
        let chat = try #require(allResults.items.first { $0.id.rawValue == "thread-match" })

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-match", workspace: workspaceURL, name: "Match")
        ]))
        let filteredResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await filteredResults.performFetch()
        #expect(filteredResults.items.isEmpty == false)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-match"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-match",
            workspace: workspaceURL,
            name: "Renamed"
        ))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await context.refresh(chat, includeTurns: false)

        #expect(filteredResults.items.isEmpty == false)
    }

    @Test("removing the last chat removes the workspace from its group")
    func removingLastChatRemovesWorkspaceFromGroup() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
        ]))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let workspace = try #require(chat.workspace)
        let group = try #require(workspace.workspaceGroup)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        #expect(workspace.chats.isEmpty)
        #expect(group.workspaces.isEmpty)
    }

    @Test("deleting a chat removes it from active fetched results")
    func deletingChatRemovesItFromActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)
        let page = try DataKitTestThreadPage(profile: .partialDTO, threads: [
            .init(
                id: "thread-delete",
                workspace: workspaceURL,
                name: "Delete",
                sourceKind: .cli,
                turns: [
                    .init(
                        id: "turn-delete",
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "item-delete",
                                kind: .enteredReviewMode,
                                content: .log("Delete")
                            )
                        ]
                    )
                ]
            )
        ])

        try await runtime.transport.enqueueUserVisibleThreadList(page)
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let chat = try #require(chatResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(page)
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(page)
        let groupResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()
        let turn = try #require(chat.turns.first)
        let item = try #require(chat.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        #expect(chatResults.items.isEmpty)
        #expect(chatResults.sections.isEmpty)
        #expect(workspaceResults.items.isEmpty)
        #expect(groupResults.items.isEmpty)
        #expect(chat.modelContext == nil)
        #expect(chat.turns.isEmpty)
        #expect(chat.items.isEmpty)
        #expect(turn.modelContext == nil)
        #expect(turn.chat == nil)
        #expect(turn.items.isEmpty)
        #expect(item.modelContext == nil)
        #expect(item.chat == nil)
        #expect(item.turn == nil)

        try await runtime.transport.enqueueUserVisibleThreadList(page)
        try await chatResults.performFetch()
        let replacementChat = try #require(chatResults.items.first)
        let replacementTurn = try #require(replacementChat.turns.first)
        let replacementItem = try #require(replacementChat.items.first)
        #expect(replacementChat !== chat)
        #expect(replacementTurn !== turn)
        #expect(replacementItem !== item)
    }

    @Test("deleting an observed chat cancels its active observation")
    func deletingObservedChatCancelsActiveObservation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-delete-observed", workspace: workspaceURL, name: "Delete")
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let chat = try #require(chatResults.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-delete-observed"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-delete-observed",
            workspace: workspaceURL,
            name: "Delete"
        ))
        let observation = try await chat.observe()
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await chat.delete()

        #expect(chat.modelContext == nil)
        #expect(await eventually { changes.isFinished })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-delete-observed"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-delete-observed",
            workspace: workspaceURL,
            name: "Delete Replacement"
        ))
        let replacement = context.model(for: CodexThreadID(rawValue: "thread-delete-observed"))
        let replacementObservation = try await replacement.observe()
        defer {
            replacementObservation.cancel()
        }

        #expect(replacement.modelContext === context)
        #expect(replacement.name == "Delete Replacement")
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 2)
        withExtendedLifetime(changes) {}
    }

    @Test("server-filtered delete removes known chat when refresh fails")
    func serverFilteredDeleteRemovesKnownChatWhenRefreshFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-delete", name: "Delete")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await chat.delete()

        #expect(results.items.isEmpty)
        #expect(chat.modelContext == nil)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("server-only parent results keep parents after local child removal")
    func serverOnlyParentResultsKeepParentsAfterLocalChildRemoval() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let chatResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await chatResults.performFetch()
        let chat = try #require(chatResults.items.first { $0.id.rawValue == "thread-delete" })

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-delete", workspace: workspaceURL, name: "Delete"),
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining"),
        ]))
        let groupResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspaceGroup>.workspaceGroups)
        try await groupResults.performFetch()

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-remaining", workspace: workspaceURL, name: "Remaining")
        ]))
        try await chat.delete()

        #expect(workspaceResults.items.first?.url == workspaceURL)
        #expect(groupResults.items.first?.workspaces.first?.url == workspaceURL)
    }

    @Test("paged fetched results backfill after local removals")
    func pagedFetchedResultsBackfillAfterLocalRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueBoundedUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-backfill", workspace: workspaceURL, name: "Backfill")
        ]))
        try await chat.delete()

        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("server-paginated fetched results backfill without explicit limits")
    func serverPaginatedFetchedResultsBackfillWithoutExplicitLimits() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-delete", workspace: workspaceURL, name: "Delete")
            ],
            nextCursor: "next"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\CodexChat.recencyAt, order: .reverse)]
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-backfill", workspace: workspaceURL, name: "Backfill")
        ]))
        try await chat.delete()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let backfillParams = try #require(requests.last).decodeParams(ThreadListParams.self)
        #expect(backfillParams.cursor == nil)
        #expect(backfillParams.limit == nil)
        #expect(results.items.map(\.id.rawValue) == ["thread-backfill"])
    }

    @Test("paged fetched results preserve loaded pages while backfilling")
    func pagedFetchedResultsPreserveLoadedPagesWhileBackfilling() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let deleteRecency = Date(timeIntervalSince1970: 300)
        let keepRecency = Date(timeIntervalSince1970: 200)
        let backfillRecency = Date(timeIntervalSince1970: 100)

        try await runtime.transport.enqueueBoundedUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(
                    id: "thread-delete",
                    workspace: workspaceURL,
                    name: "Delete",
                    recencyAt: deleteRecency
                )
            ],
            nextCursor: "page-2"
        ))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueBoundedUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(
                    id: "thread-delete",
                    workspace: workspaceURL,
                    name: "Delete",
                    recencyAt: deleteRecency
                ),
                .init(
                    id: "thread-keep",
                    workspace: workspaceURL,
                    name: "Keep",
                    recencyAt: keepRecency
                )
            ],
            nextCursor: "page-3"
        ))
        try await results.loadNextPage()

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-keep",
                workspace: workspaceURL,
                name: "Keep",
                recencyAt: keepRecency
            ),
            .init(
                id: "thread-backfill",
                workspace: workspaceURL,
                name: "Backfill",
                recencyAt: backfillRecency
            ),
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-keep",
                workspace: workspaceURL,
                name: "Keep",
                recencyAt: keepRecency
            ),
            .init(
                id: "thread-backfill",
                workspace: workspaceURL,
                name: "Backfill",
                recencyAt: backfillRecency
            ),
        ]))
        try await chat.delete()

        let requests = await runtime.transport.recordedRequests(method: "thread/list")
        let refillParams = try requests.suffix(4).map {
            try $0.decodeParams(ThreadListParams.self)
        }
        #expect(requests.count == 8)
        #expect(refillParams.map(\.limit) == [1, 1, 2, 2])
        #expect(results.items.map(\.id.rawValue) == ["thread-keep", "thread-backfill"])
    }

    @Test("local paged fetched results recompute backfill cursors after removals")
    func localPagedFetchedResultsRecomputeBackfillCursorsAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        try await chat.delete()

        #expect(results.items.map(\.id.rawValue) == ["thread-b", "thread-c"])
    }

    @Test("local paged fetched results preserve starting cursor when loading next page")
    func localPagedFetchedResultsPreserveStartingCursorWhenLoadingNextPage() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let threads = [
            DataKitTestThreadFixture(id: "thread-a", workspace: workspaceURL, name: "A"),
            DataKitTestThreadFixture(id: "thread-b", workspace: workspaceURL, name: "B"),
            DataKitTestThreadFixture(id: "thread-c", workspace: workspaceURL, name: "C"),
            DataKitTestThreadFixture(id: "thread-d", workspace: workspaceURL, name: "D"),
        ]

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: threads))
        let firstPage = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await firstPage.performFetch()
        _ = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: threads))
        let offsetPage = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1,
            fetchOffset: 2
        ))
        try await offsetPage.performFetch()
        #expect(offsetPage.items.map(\.title) == ["C"])

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: threads))
        try await offsetPage.loadNextPage()

        #expect(offsetPage.items.map(\.title) == ["C", "D"])
        #expect(offsetPage.nextCursor == nil)
    }

    @Test("local paged fetched results backfill from starting cursor offset after removals")
    func localPagedFetchedResultsBackfillFromStartingCursorOffsetAfterRemovals() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialThreads = [
            DataKitTestThreadFixture(id: "thread-a", workspace: workspaceURL, name: "A"),
            DataKitTestThreadFixture(id: "thread-b", workspace: workspaceURL, name: "B"),
            DataKitTestThreadFixture(id: "thread-c", workspace: workspaceURL, name: "C"),
            DataKitTestThreadFixture(id: "thread-d", workspace: workspaceURL, name: "D"),
            DataKitTestThreadFixture(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: initialThreads))
        let firstPage = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await firstPage.performFetch()
        _ = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2,
            fetchOffset: 2
        ))
        try await offsetPage.performFetch()
        let deletedChat = try #require(offsetPage.items.first)
        #expect(offsetPage.items.map(\.title) == ["C", "D"])

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-d", workspace: workspaceURL, name: "D"),
            .init(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-d", workspace: workspaceURL, name: "D"),
            .init(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]))
        try await deletedChat.delete()

        #expect(offsetPage.items.map(\.title) == ["D", "E"])
        #expect(offsetPage.nextCursor == nil)
    }

    @Test("cursor-started local pages refetch when earlier chats are removed")
    func cursorStartedLocalPagesRefetchWhenEarlierChatsAreRemoved() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialThreads = [
            DataKitTestThreadFixture(id: "thread-a", workspace: workspaceURL, name: "A"),
            DataKitTestThreadFixture(id: "thread-b", workspace: workspaceURL, name: "B"),
            DataKitTestThreadFixture(id: "thread-c", workspace: workspaceURL, name: "C"),
            DataKitTestThreadFixture(id: "thread-d", workspace: workspaceURL, name: "D"),
            DataKitTestThreadFixture(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: initialThreads))
        var firstPage: CodexFetchedResults<CodexChat>? = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2
        ))
        try await firstPage?.performFetch()
        _ = try #require(firstPage?.nextCursor)
        let deletedChat = context.model(for: CodexThreadID(rawValue: "thread-a"))
        firstPage = nil

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2,
            fetchOffset: 2
        ))
        try await offsetPage.performFetch()
        #expect(offsetPage.items.map(\.title) == ["C", "D"])

        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "B"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
            .init(id: "thread-d", workspace: workspaceURL, name: "D"),
            .init(id: "thread-e", workspace: workspaceURL, name: "E"),
        ]))
        try await deletedChat.delete()

        #expect(offsetPage.items.map(\.title) == ["D", "E"])
    }

    @Test("cursor-started local pages refetch when visible chats move before the cursor")
    func cursorStartedLocalPagesRefetchWhenVisibleChatsMoveBeforeCursor() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let initialThreads = [
            DataKitTestThreadFixture(id: "thread-a", workspace: workspaceURL, name: "A"),
            DataKitTestThreadFixture(id: "thread-b", workspace: workspaceURL, name: "B"),
            DataKitTestThreadFixture(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: initialThreads))
        let firstPage = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await firstPage.performFetch()
        _ = try #require(firstPage.nextCursor)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: initialThreads))
        let offsetPage = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 2,
            fetchOffset: 1
        ))
        try await offsetPage.performFetch()
        let movingChat = try #require(offsetPage.items.first)
        #expect(offsetPage.items.map(\.title) == ["B", "C"])
        #expect(offsetPage.nextCursor == nil)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-b"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-b",
            workspace: workspaceURL,
            name: "0"
        ))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "0"),
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-b", workspace: workspaceURL, name: "0"),
            .init(id: "thread-a", workspace: workspaceURL, name: "A"),
            .init(id: "thread-c", workspace: workspaceURL, name: "C"),
        ]))
        try await context.refresh(movingChat, includeTurns: false)

        #expect(offsetPage.items.map(\.title) == ["A", "C"])
        #expect(offsetPage.nextCursor == nil)
    }

    @Test("starting a chat inserts it into active fetched results")
    func startingChatInsertsItIntoActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let workspace = try #require(results.items.first?.workspace)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        let chat = try await workspace.startChat()

        #expect(results.items.first === chat)
        #expect(results.sections.first?.items.first === chat)
        #expect(chat.source == .appServer)
        #expect(chat.sourceKind == .appServer)
    }

    @Test("starting a chat excludes it from fetched results when pending changes are disabled")
    func startingChatExcludesItFromFetchedResultsWhenPendingChangesAreDisabled() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let existing = DataKitTestThreadFixture(
            id: "thread-existing",
            workspace: workspaceURL,
            name: "Existing",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [existing]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [existing]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            includeContextChanges: false
        ))
        try await results.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [existing]))
        let chat = try await workspace.startChat()

        #expect(chat.id == "thread-new")
        #expect(results.items.map(\.id.rawValue) == ["thread-existing"])
    }

    @Test("starting a chat preserves requested provider for filtered results")
    func startingChatPreservesRequestedProviderForFilteredResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let providerResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: modelProviderChatPredicate(["openai"])
        ))
        try await providerResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-new",
                workspace: workspaceURL,
                name: "New",
                modelProvider: "openai"
            )
        ]))
        let chat = try await workspace.startChat(.init(
            options: .init(modelProvider: "openai")
        ))

        #expect(chat.modelProvider == "openai")
        #expect(providerResults.items.first === chat)
    }

    @Test("starting a chat refreshes provider-filtered results when provider is unknown")
    func startingChatRefreshesProviderFilteredResultsWhenProviderIsUnknown() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let providerResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: modelProviderChatPredicate(["openai"])
        ))
        try await providerResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-new",
                workspace: workspaceURL,
                name: "New",
                modelProvider: "openai"
            )
        ]))
        let chat = try await workspace.startChat()

        #expect(chat.modelProvider == "openai")
        #expect(providerResults.items.first === chat)
    }

    @Test("starting a chat refreshes server-filtered fetched results")
    func startingChatRefreshesServerFilteredFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: []))
        let serverResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.appServer])
        ))
        try await serverResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(
                id: "thread-new",
                workspace: workspaceURL,
                name: "New"
            ).withSourceKind(.appServer)
        ]))
        let chat = try await workspace.startChat()

        #expect(serverResults.items.first === chat)
    }

    @Test("empty provider filters revalidate as all providers")
    func emptyProviderFiltersRevalidateAsAllProviders() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-any-provider", name: "Before")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>())
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-any-provider"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-any-provider",
            name: "After"
        ))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-any-provider", name: "After")
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
        #expect(chat.title == "After")
    }

    @Test("starting a chat updates limited fetched results without overfilling")
    func startingChatUpdatesLimitedFetchedResultsWithoutOverfilling() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let pagedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        _ = try await workspace.startChat()

        #expect(pagedResults.items.count == 1)
        #expect(pagedResults.items.first?.id.rawValue == "thread-new")
        #expect(pagedResults.nextCursor != nil)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-new", workspace: workspaceURL, name: "New", updatedAt: Date()),
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing"),
        ]))
        try await pagedResults.loadNextPage()

        #expect(pagedResults.items.map(\.id.rawValue) == ["thread-new", "thread-existing"])
        #expect(pagedResults.nextCursor == nil)
        let listRequests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(listRequests.count == 6)
        let nextPageParams = try #require(listRequests.last).decodeParams(ThreadListParams.self)
        #expect(nextPageParams.cursor == nil)
    }

    @Test("starting a chat inserts into underfilled limited fetched results")
    func startingChatInsertsIntoUnderfilledLimitedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let limitedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 2
        ))
        try await limitedResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        _ = try await workspace.startChat()

        #expect(limitedResults.items.map(\.id.rawValue) == ["thread-new", "thread-existing"])
    }

    @Test("starting a chat refreshes incomplete paged fetched results")
    func startingChatRefreshesIncompletePagedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
        ]))
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
            ],
            nextCursor: "next"
        ))
        let pagedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(id: "thread-new", workspace: workspaceURL, name: "New")
            ],
            nextCursor: "next"
        ))
        _ = try await workspace.startChat()

        #expect(pagedResults.items.map(\.id.rawValue) == ["thread-new"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 4)
    }

    @Test("loaded limited pages stay loaded after local revalidation")
    func loadedLimitedPagesStayLoadedAfterLocalRevalidation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspaceURL, name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspaceURL, name: "Alpha"),
            .init(id: "thread-beta", workspace: workspaceURL, name: "Beta"),
        ]))
        try await results.loadNextPage()
        let beta = try #require(results.items.last)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-beta"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-beta",
            workspace: workspaceURL,
            name: "Gamma"
        ))
        try await context.refresh(beta, includeTurns: false)

        #expect(results.items.map(\.title) == ["Alpha", "Gamma"])
    }

    @Test("starting a chat preserves the loaded paged window bound")
    func startingChatPreservesLoadedPagedWindowBound() async throws {
        let workspaceURL = temporaryDirectory()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let newerThread = try makeDataKitStoredThreadFixture(
            id: "thread-newer",
            workspace: workspaceURL,
            name: "Newer",
            updatedAt: newer
        )
        let olderThread = try makeDataKitStoredThreadFixture(
            id: "thread-older",
            workspace: workspaceURL,
            name: "Older",
            updatedAt: older
        )
        let plannedStart = try makeDataKitStoredThreadFixture(
            id: "thread-started",
            workspace: workspaceURL
        )
        let store = try CodexAppServerTestThreadStore(
            threads: [newerThread, olderThread],
            plannedStarts: [plannedStart]
        )
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceResults = context.fetchedResults(for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        let pagedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()
        try await pagedResults.loadNextPage()
        let listRequestCount = await runtime.transport.recordedRequests(method: "thread/list").count

        let started = try await workspace.startChat()

        #expect(pagedResults.items.map(\.id.rawValue) == [
            started.id.rawValue,
            "thread-newer",
        ])
        #expect(pagedResults.nextCursor != nil)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == listRequestCount)
    }

    @Test("archiving a chat moves it between active fetched results")
    func archivingChatMovesItBetweenActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let unarchivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await unarchivedResults.performFetch()
        let chat = try #require(unarchivedResults.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        #expect(unarchivedResults.items.isEmpty)
        #expect(archivedResults.items.first === chat)
    }

    @Test("empty chat predicates keep local sort results active after archive")
    func emptyChatPredicatesKeepLocalSortResultsActiveAfterArchive() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)]
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let requestCount = await runtime.transport.recordedRequests(method: "thread/list").count

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        #expect(results.items.isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == requestCount)
    }

    @Test("implicit active scope applies to locally matched filtered results")
    func implicitActiveScopeAppliesToLocallyMatchedFilteredResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archive", workspace: workspaceURL, name: "Archive")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: workspaceChatPredicate(workspaceURL),
            sortBy: [CodexSortDescriptor(\.name)]
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let requestCount = await runtime.transport.recordedRequests(method: "thread/list").count

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        #expect(results.items.isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == requestCount)
    }

    @Test("server-filtered archive removes active chat when refresh fails")
    func serverFilteredArchiveRemovesActiveChatWhenRefreshFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-archive", workspace: workspaceURL, name: "Archive")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedSourceKindChatPredicate(archived: false, sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await chat.archive()

        #expect(results.items.isEmpty)
        #expect(chat.isArchived)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("unarchiving a chat moves it between active fetched results")
    func unarchivingChatMovesItBetweenActiveFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-unarchive", workspace: workspaceURL, name: "Archived")
                .withSourceKind(.appServer)
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let chat = try #require(archivedResults.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let unarchivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await unarchivedResults.performFetch()

        try await runtime.transport.enqueueThreadUnarchive(.init(
            id: "thread-unarchive",
            workspace: workspaceURL,
            name: "Restored"
        ))
        try await chat.unarchive()

        #expect(chat.isArchived == false)
        #expect(chat.title == "Restored")
        #expect(archivedResults.items.isEmpty)
        #expect(unarchivedResults.items.first === chat)
        #expect(chat.workspace?.chats.first === chat)
    }

    @Test("server-filtered unarchive removes archived chat when refresh fails")
    func serverFilteredUnarchiveRemovesArchivedChatWhenRefreshFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-unarchive", workspace: workspaceURL, name: "Archived")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedSourceKindChatPredicate(archived: true, sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadUnarchive(.init(
            id: "thread-unarchive",
            workspace: workspaceURL,
            name: "Restored"
        ))
        await runtime.transport.enqueueFailure(code: -32000, message: "offline", for: "thread/list")
        try await chat.unarchive()

        #expect(results.items.isEmpty)
        #expect(chat.isArchived == false)
        #expect(chat.title == "Restored")
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)
    }

    @Test("archiving a chat inserts it into archived fetched results")
    func archivingChatInsertsItIntoArchivedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let workspaceURL = try createDirectory("App", in: repo)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-archive", workspace: workspaceURL, name: "Archive")
                .withSourceKind(.appServer)
        ]))
        let unarchivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await unarchivedResults.performFetch()
        let chat = try #require(unarchivedResults.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await chat.archive()

        #expect(archivedResults.items.first === chat)
        #expect(chat.workspace?.url == workspaceURL)
    }

    @Test("archived refresh prunes removed archived relationships")
    func archivedRefreshPrunesRemovedArchivedRelationships() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-archived", workspace: workspaceURL, name: "Archived")
        ]))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedChatPredicate(true),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try await archivedResults.performFetch()
        let chat = try #require(archivedResults.items.first)
        let workspace = try #require(chat.workspace)
        let group = try #require(workspace.workspaceGroup)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: []))
        try await archivedResults.performFetch()

        #expect(archivedResults.items.isEmpty)
        #expect(workspace.chats.isEmpty)
        #expect(group.workspaces.contains { $0 === workspace } == false)
    }

    @Test("archiving a chat refreshes server-filtered archived results")
    func archivingChatRefreshesServerFilteredArchivedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: []))
        let archivedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: archivedSourceKindChatPredicate(archived: true, sourceKinds: [.appServer])
        ))
        try await archivedResults.performFetch()

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: []))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-archive", workspace: workspaceURL, name: "Archive")
                .withSourceKind(.appServer)
        ]))
        let activeResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await activeResults.performFetch()
        let chat = try #require(activeResults.items.first)

        try await runtime.transport.enqueueEmpty(for: "thread/archive")
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-archive", workspace: workspaceURL, name: "Archive")
                .withSourceKind(.appServer)
        ]))
        try await chat.archive()

        #expect(activeResults.items.isEmpty)
        #expect(archivedResults.items.first === chat)
    }

    @Test("metadata-only chat refresh preserves existing turn objects")
    func metadataOnlyRefreshPreservesTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let updatedAt = Date(timeIntervalSince1970: 1_000)

        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .partialDTO, threads: [
                .init(
                    id: "thread-refresh",
                    workspace: workspaceURL,
                    name: "Before",
                    modelProvider: "openai",
                    sourceKind: .cli,
                    updatedAt: updatedAt,
                    turns: [.init(id: "turn-refresh", state: .inProgress)]
                )
            ]))

        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let turn = try #require(chat.turns.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh"))
        try await runtime.transport.enqueue(
            AppServerAPI.Thread.Read.Response(thread: DataKitTestThreadFixture(
                id: "thread-refresh",
                name: "After",
                turns: []
            ).dto(profile: .partialDTO)),
            for: "thread/read"
        )

        try await context.refresh(chat, includeTurns: false)

        #expect(chat.title == "After")
        #expect(chat.workspace?.url == workspaceURL)
        #expect(chat.modelProvider == "openai")
        #expect(chat.updatedAt == updatedAt)
        #expect(chat.turns.first === turn)
        #expect(turn.status == CodexTurnStatus.inProgress)

        let request = try #require(
            await runtime.transport.recordedRequests(method: "thread/read").first)
        let params = try request.decodeParams(ThreadReadParams.self)
        #expect(params.threadID == "thread-refresh")
        #expect(params.includeTurns == false)
    }

    @Test("metadata-only thread status never synthesizes a terminal turn state")
    func metadataOnlyThreadStatusNeverSynthesizesTerminalTurnState() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-metadata-phase"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-metadata-phase",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-stale", state: .inProgress)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-metadata-phase"))
        try await context.refresh(chat)
        #expect(chat.phase == .running(turnID: "turn-stale"))

        for status: CodexThreadStatus in [.idle, .notLoaded, .systemError] {
            try await runtime.transport.enqueueThreadResume(.init(id: "thread-metadata-phase"))
            try await runtime.transport.enqueueThreadRead(.init(
                id: "thread-metadata-phase",
                status: status
            ))

            try await context.refresh(chat, includeTurns: false)

            #expect(chat.turn(id: "turn-stale")?.state == .inProgress)
            #expect(chat.phase == .idle)
            #expect(chat.status == status)
        }
    }

    @Test("turn snapshots without fresh thread status preserve app-server thread status")
    func turnSnapshotsWithoutFreshThreadStatusPreserveAppServerThreadStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-stale-status"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-stale-status",
            status: .idle
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-stale-status"))
        try await context.refresh(chat, includeTurns: false)
        #expect(chat.status == .idle)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-stale-status"))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-running-after-idle",
                state: .inProgress,
                items: [
                    .init(
                        id: "command-running-after-idle",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "/bin/zsh -lc",
                            status: .inProgress,
                            startedAt: Date(timeIntervalSince1970: 4_000)
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-stale-status"))

        try await context.refresh(chat)

        let turn = try #require(chat.turn(id: "turn-running-after-idle"))
        let commandItem = try #require(chat.items.first { $0.itemID == "command-running-after-idle" })
        guard case .command(let command) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(turn.status == .inProgress)
        #expect(command.status == .inProgress)
        #expect(command.completedAt == nil)
        #expect(chat.status == .idle)
        #expect(chat.phase == .running(turnID: "turn-running-after-idle"))
    }

    @Test("chat refresh cancellation restores its stable typed phase")
    func chatRefreshCancellationRestoresStablePhase() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let readGate = CodexAppServerTestGate()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-cancel-refresh"))

        try await runtime.transport.enqueueThreadResume(.init(id: chat.id))
        try await runtime.transport.enqueueThreadRead(.init(id: chat.id, status: .idle))
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/read",
            gate: readGate
        )
        let refresh = Task { @MainActor in
            try await context.refresh(chat, includeTurns: false)
        }
        await runtime.transport.waitForRequest(method: "thread/read")

        refresh.cancel()
        await readGate.open()
        do {
            try await refresh.value
            Issue.record("Expected chat refresh cancellation")
        } catch is CancellationError {
        }

        #expect(chat.phase == .idle)
    }

    @Test("cancelled chat operations do not overwrite a newer live terminal phase")
    func cancelledChatOperationPreservesNewerTerminalPhase() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-cancel-live-terminal"))

        chat.beginLoading()
        _ = chat.apply(.completed(CodexResponse(turnID: "turn-live-terminal")))
        chat.restorePhaseIfLoading(.idle)

        #expect(chat.phase == .terminal(
            turnID: "turn-live-terminal",
            disposition: .completed
        ))
    }

    @Test("chat observation setup cancellation releases its slot and restores phase")
    func chatObservationSetupCancellationReleasesSlot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let readGate = CodexAppServerTestGate()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-cancel-observe"))

        try await runtime.transport.enqueueThreadResume(.init(id: chat.id))
        try await runtime.transport.enqueueThreadRead(.init(id: chat.id, status: .idle))
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/read",
            gate: readGate
        )
        let setup = Task { @MainActor in
            do {
                _ = try await chat.observe(includeTurns: false)
                Issue.record("Expected chat observation setup cancellation")
            } catch is CancellationError {
            } catch {
                Issue.record("Unexpected chat observation setup error: \(error)")
            }
        }
        await runtime.transport.waitForRequest(method: "thread/read")

        setup.cancel()
        await readGate.open()
        await setup.value
        #expect(chat.phase == .idle)

        try await runtime.transport.enqueueThreadResume(.init(id: chat.id))
        try await runtime.transport.enqueueThreadRead(.init(id: chat.id, status: .idle))
        let observation = try await chat.observe(includeTurns: false)
        observation.cancel()
    }

    @Test("fresh idle thread status does not rewrite a running turn snapshot")
    func freshIdleThreadStatusDoesNotRewriteRunningTurnSnapshot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-idle-with-running-turn"))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-stale-running",
                state: .inProgress,
                items: [
                    .init(
                        id: "command-stale-running",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "/bin/zsh -lc",
                            status: .inProgress,
                            startedAt: Date(timeIntervalSince1970: 4_500)
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-idle-with-running-turn",
            status: .idle
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-idle-with-running-turn"))
        try await context.refresh(chat)

        #expect(chat.status == .idle)
        #expect(chat.phase == .running(turnID: "turn-stale-running"))
        #expect(chat.turn(id: "turn-stale-running")?.state == .inProgress)
    }

    @Test("server-only chat refresh re-sorts current results")
    func serverOnlyChatRefreshResortsCurrentResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-beta", name: "Beta")
                .withSourceKind(.appServer),
            DataKitTestThreadFixture(id: "thread-alpha", name: "Alpha")
                .withSourceKind(.appServer),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.appServer]),
            sortBy: [CodexSortDescriptor(\.name)]
        ))
        try await results.performFetch()
        let beta = try #require(results.items.first { $0.id.rawValue == "thread-beta" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-beta"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-beta", name: "Aardvark"))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-beta", name: "Aardvark")
                .withSourceKind(.appServer),
            DataKitTestThreadFixture(id: "thread-alpha", name: "Alpha")
                .withSourceKind(.appServer),
        ]))
        try await context.refresh(beta, includeTurns: false)

        #expect(results.items.map(\.title) == ["Aardvark", "Alpha"])
    }

    @Test("server-only chat refresh applies local workspace filters")
    func serverOnlyChatRefreshAppliesLocalWorkspaceFilters() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try gitRepository()
        let app = try createDirectory("App", in: repo)
        let tools = try createDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: [
            DataKitTestThreadFixture(id: "thread-move", workspace: app, name: "Move")
                .withSourceKind(.appServer)
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: workspaceSourceKindChatPredicate(workspace: app, sourceKinds: [.appServer])
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-move"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-move",
            workspace: tools,
            name: "Move"
        ))
        try await runtime.transport.enqueueThreadList(.init(profile: .currentV2, threads: []))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.isEmpty)
    }

    @Test("search-filtered chat refresh reloads server membership")
    func searchFilteredChatRefreshReloadsServerMembership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-search", name: "needle")
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: searchChatPredicate("needle")
        ))
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-search"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-search", name: "needle"))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-search", name: "needle")
        ]))
        try await context.refresh(chat, includeTurns: false)

        #expect(results.items.first === chat)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 4)
    }

    @Test("thread list fetch coalesces locally filtered revalidations")
    func threadListFetchCoalescesLocallyFilteredRevalidations() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-first", name: "First", preview: "needle"),
            .init(id: "thread-second", name: "Second", preview: "needle"),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await allResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-first", name: "First", preview: "needle"),
            .init(id: "thread-second", name: "Second", preview: "needle"),
        ]))
        let searchResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: searchChatPredicate("needle")
        ))
        try await searchResults.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-first", name: "First renamed", preview: "needle"),
            .init(id: "thread-second", name: "Second renamed", preview: "needle"),
        ]))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-first", name: "First renamed", preview: "needle"),
            .init(id: "thread-second", name: "Second renamed", preview: "needle"),
        ]))
        try await allResults.performFetch()

        #expect(searchResults.items.map(\.title) == ["Second renamed", "First renamed"])
        let recordedRequests = await runtime.transport.recordedRequests(method: "thread/list")
        #expect(recordedRequests.count == 8)
        let refreshParams = try #require(recordedRequests.last).decodeParams(ThreadListParams.self)
        #expect(refreshParams.searchTerm == nil)
    }

    @Test("paged chat refresh reloads incomplete results after sort key changes")
    func pagedChatRefreshReloadsIncompleteResultsAfterSortKeyChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.name)],
            fetchLimit: 1
        ))
        try await results.performFetch()
        let alpha = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-alpha", name: "Zulu"))
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Zulu"),
            .init(id: "thread-beta", name: "Beta"),
        ]))
        try await context.refresh(alpha, includeTurns: false)

        #expect(results.items.map(\.id.rawValue) == ["thread-beta"])
    }

    @Test("thread list empty turn arrays preserve cached turns and items")
    func threadListEmptyTurnArraysPreserveCachedTurnsAndItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-clear",
                name: "Before",
                sourceKind: .cli,
                turns: [
                    .init(
                        id: "turn-clear",
                        state: .completed,
                        items: [
                            .init(
                                id: "message-clear",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-clear",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(id: "thread-clear", name: "After", sourceKind: .cli, turns: [])
        ]))
        try await results.refresh()

        #expect(chat.title == "After")
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)
    }

    @Test("thread list summary turns preserve cached transcript items")
    func threadListSummaryTurnsPreserveCachedTranscriptItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-summary",
                name: "Before",
                sourceKind: .cli,
                turns: [
                    .init(
                        id: "turn-summary",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "message-summary",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-summary",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    ),
                    .init(
                        id: "turn-omitted",
                        state: .inProgress
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        let turn = try #require(chat.turns.first)
        let item = try #require(chat.items.first)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-summary",
                name: "After",
                sourceKind: .cli,
                turns: [
                    .init(
                        id: "turn-summary",
                        state: .completed,
                        itemsLoadState: .summary,
                        items: [
                            .init(
                                id: "message-summary",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-summary",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Summary placeholder"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        try await results.refresh()

        #expect(chat.title == "After")
        #expect(chat.turns.first === turn)
        #expect(turn.status == CodexTurnStatus.completed)
        #expect(chat.turns.contains { $0.id == "turn-omitted" })
        #expect(chat.items.first === item)
        #expect(item.text == "Done")
        #expect(chat.transcript.finalAnswer == "Done")
    }

    @Test("explicit empty read turn lists clear cached turns and items")
    func explicitEmptyReadTurnListsClearCachedTurnsAndItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-clear",
                name: "Before",
                sourceKind: .cli,
                turns: [
                    .init(
                        id: "turn-clear",
                        state: .completed,
                        items: [
                            .init(
                                id: "message-clear",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-clear",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-clear"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-clear",
            name: "After",
            turns: []
        ))
        try await context.refresh(chat)

        #expect(chat.turns.isEmpty)
        #expect(chat.items.isEmpty)
    }

    @Test("included reads without turns clear cached turns and items")
    func includedReadsWithoutTurnsClearCachedTurnsAndItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .partialDTO, threads: [
            .init(
                id: "thread-omitted-read",
                name: "Before",
                sourceKind: .cli,
                turns: [
                    .init(
                        id: "turn-omitted-read",
                        state: .completed,
                        items: [
                            .init(
                                id: "message-omitted-read",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "message-omitted-read",
                                    role: .assistant,
                                    phase: .finalAnswer,
                                    text: "Done"
                                ))
                            ),
                        ]
                    )
                ]
            )
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let chat = try #require(results.items.first)
        #expect(chat.turns.isEmpty == false)
        #expect(chat.items.isEmpty == false)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-omitted-read"))
        try await runtime.transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-omitted-read",
                "name": "After"
              }
            }
            """,
            for: "thread/read"
        )
        try await context.refresh(chat)

        #expect(chat.title == "After")
        #expect(chat.turns.isEmpty)
        #expect(chat.items.isEmpty)
    }

    @Test("chat refresh populates transcript items from turn history")
    func chatRefreshPopulatesTranscriptItemsFromTurnHistory() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-history"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-history",
            turns: [
                .init(
                    id: "turn-history",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-history",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-history",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Done"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-history"))
        try await context.refresh(chat)

        let item = try #require(chat.items.first)
        #expect(chat.items.count == 1)
        #expect(item.itemID == "message-history")
        #expect(item.turnID == "turn-history")
        #expect(item.text == "Done")
        #expect(chat.transcript.finalAnswer == "Done")
    }

    @Test("chat refresh loads full turn items through thread turns list")
    func chatRefreshLoadsFullTurnItemsThroughThreadTurnsList() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-turns-list"))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-live",
                state: .inProgress,
                items: [
                    .init(
                        id: "message-live",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-live",
                            role: .assistant,
                            text: "Active turn snapshot"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-turns-list",
            name: "Turns list"
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-turns-list"))
        try await context.refresh(chat)

        #expect(chat.title == "Turns list")
        #expect(chat.items.map(\.text) == ["Active turn snapshot"])
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 1)
        let readRequest = try #require(await runtime.transport.recordedRequests(method: "thread/read").first)
        let readParams = try readRequest.decodeParams(ThreadReadParams.self)
        #expect(readParams.includeTurns == false)
    }

    @Test("chat refresh follows all turn-list pages before applying authoritative turns")
    func chatRefreshFollowsAllTurnListPagesBeforeApplyingAuthoritativeTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-turns-pages"))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2,
            turns: [
                .init(
                    id: "turn-page-1",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-page-1",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-page-1",
                                role: .assistant,
                                text: "First page"
                            ))
                        ),
                    ]
                ),
            ],
            nextCursor: "page-2"
        ))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-page-2",
                state: .completed,
                items: [
                    .init(
                        id: "message-page-2",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-page-2",
                            role: .assistant,
                            text: "Second page"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-turns-pages",
            name: "Turns pages"
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-turns-pages"))
        try await context.refresh(chat)

        #expect(chat.items.map(\.text) == ["First page", "Second page"])
        #expect(chat.turns.map(\.id.rawValue) == ["turn-page-1", "turn-page-2"])
        let requests = await runtime.transport.recordedRequests(method: "thread/turns/list")
        #expect(requests.count == 2)
        let firstParams = try #require(requests.first).decodeParams(ThreadTurnsListParams.self)
        let secondParams = try #require(requests.dropFirst().first).decodeParams(ThreadTurnsListParams.self)
        #expect(firstParams.cursor == nil)
        #expect(secondParams.cursor == "page-2")
    }

    @Test("chat turn helpers scope items and preserve identity")
    func chatTurnHelpersScopeItemsAndPreserveIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-snapshot"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-snapshot",
            turns: [
                .init(
                    id: "turn-alpha",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-alpha-user",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "message-alpha-user",
                                role: .user,
                                text: "Question"
                            ))
                        ),
                        .init(
                            id: "message-alpha-agent",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-alpha-agent",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Alpha answer"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-beta",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "message-beta",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-beta",
                                role: .assistant,
                                text: "Beta update"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-snapshot"))
        try await context.refresh(chat)

        let alphaTurn = try #require(chat.turn(id: "turn-alpha"))
        let alphaItem = try #require(chat.items.first { $0.itemID == "message-alpha-user" })
        let alphaItems = chat.items(in: "turn-alpha")
        let betaItems = chat.items(in: "turn-beta")
        let alphaThreadItems = threadItems(from: alphaItems)

        #expect(alphaItems.map(\.itemID) == ["message-alpha-user", "message-alpha-agent"])
        #expect(betaItems.map(\.itemID) == ["message-beta"])
        #expect(alphaItems.first === alphaItem)
        #expect(alphaTurn.status == CodexTurnStatus.completed)
        #expect(alphaTurn.error == nil)
        #expect(alphaTurn.usage == nil)
        #expect(alphaThreadItems.map(\.id) == ["message-alpha-user", "message-alpha-agent"])
        #expect(CodexTranscript(items: alphaThreadItems).finalAnswer == "Alpha answer")
    }

    @Test("chat turn helpers expose metadata and missing turn results")
    func chatTurnHelpersExposeMetadataAndMissingTurnResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-turn-metadata"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-turn-metadata",
            turns: [
                .init(
                    id: "turn-completed",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-completed",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-completed",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Done"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-failed",
                    state: .failed(.init(
                        message: "Tool failed",
                        info: .httpConnectionFailed(httpStatusCode: 503),
                        additionalDetails: "upstream detail"
                    )),
                    items: [
                        .init(
                            id: "message-failed",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-failed",
                                role: .assistant,
                                text: "Failed"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-turn-metadata"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        let failedTurn = try #require(chat.turn(id: "turn-failed"))
        #expect(failedTurn.status == CodexTurnStatus.failed)
        #expect(failedTurn.error == .init(
            message: "Tool failed",
            info: .httpConnectionFailed(httpStatusCode: 503),
            additionalDetails: "upstream detail"
        ))
        #expect(failedTurn.usage == nil)
        #expect(chat.turn(id: "turn-missing") == nil)
        #expect(chat.items(in: "turn-missing").isEmpty)

        try await runtime.transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-turn-metadata",
                turnID: "turn-completed",
                tokenUsage: .init(
                    total: .init(inputTokens: 13, outputTokens: 21, totalTokens: 34),
                    modelContextWindow: 128_000
                )
            )
        )

        #expect(await eventually {
            chat.turn(id: "turn-completed")?.usage?.totalTokens == 34
        })
        let completedTurn = try #require(chat.turn(id: "turn-completed"))
        #expect(completedTurn.usage?.inputTokens == 13)
        #expect(completedTurn.usage?.outputTokens == 21)
        #expect(completedTurn.usage?.modelContextWindow == 128_000)
        withExtendedLifetime(changes) {}
    }

    @Test("chat send merges response transcript into observable items")
    func chatSendMergesTranscriptItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-send", status: "running")

        let chat = context.model(for: CodexThreadID(rawValue: "thread-send"))
        let sendTask = Task {
            try await chat.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                lifecycle: .completed,
                threadID: "thread-send",
                turnID: "turn-send",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Done",
                    phase: "final_answer"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-send",
                turn: .init(id: "turn-send", status: "completed")
            )
        )

        let response = try await sendTask.value
        let item = try #require(chat.items.first)
        #expect(response.response.turnID == "turn-send")
        #expect(chat.turns.first?.status == CodexTurnStatus.completed)
        #expect(item.text == "Done")
        #expect(item.turnID == "turn-send")
        #expect(chat.transcript.finalAnswer == "Done")
    }

    @Test("chat send cancellation applies the interrupted terminal outcome")
    func chatSendCancellationAppliesInterruptedTerminalOutcome() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-cancelled-send"))
        try await runtime.transport.enqueueTurnStart(
            turnID: "turn-cancelled-send",
            status: "running"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")

        let chat = context.model(for: CodexThreadID(rawValue: "thread-cancelled-send"))
        let sendTask = Task {
            try await chat.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        sendTask.cancel()
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-cancelled-send",
                turn: .init(id: "turn-cancelled-send", status: "interrupted")
            )
        )

        do {
            _ = try await sendTask.value
            Issue.record("Expected the cancelled send to throw CancellationError.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }

        #expect(chat.turn(id: "turn-cancelled-send")?.status == .interrupted)
        #expect(chat.phase == .terminal(
            turnID: "turn-cancelled-send",
            disposition: .interrupted
        ))
        await runtime.close()
    }

    @Test("observed chat send emits a loaded phase change")
    func observedChatSendEmitsLoadedPhaseChange() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send-phase"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-send-phase",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-existing", state: .inProgress)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-send-phase"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let updateRecorder = ChatUpdateRecorder(stream: observation.updates)
        #expect(chat.phase == .running(turnID: "turn-existing"))

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-send-phase"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-send-phase", status: "running")
        let sendTask = Task {
            try await chat.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-send-phase",
                turn: .init(id: "turn-send-phase", status: "completed")
            )
        )

        _ = try await sendTask.value

        let phaseChange = await updateRecorder.phaseChanged(.terminal(
            turnID: "turn-send-phase",
            disposition: .completed
        ))
        #expect(phaseChange != nil)
        #expect(chat.phase == .terminal(
            turnID: "turn-send-phase",
            disposition: .completed
        ))
    }

    @Test("thread event lifecycle updates observable chat status")
    func threadEventLifecycleUpdatesObservableChatStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-status-lifecycle"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-status-lifecycle",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-status-lifecycle"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let updateRecorder = ChatUpdateRecorder(stream: observation.updates)

        #expect(chat.status == .idle)
        #expect(chat.phase == .idle)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-status-lifecycle",
                turnID: "turn-status-lifecycle"
            )
        )

        #expect(await updateRecorder.statusChanged(.active(activeFlags: [])) != nil)
        #expect(chat.status == .active(activeFlags: []))
        #expect(chat.phase == .running(turnID: "turn-status-lifecycle"))

        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-status-lifecycle",
                turn: .init(id: "turn-status-lifecycle", status: "completed")
            )
        )

        #expect(await updateRecorder.statusChanged(.idle) != nil)
        #expect(chat.status == .idle)
        #expect(chat.phase == .terminal(
            turnID: "turn-status-lifecycle",
            disposition: .completed
        ))
    }

    @Test("item lifecycle updates observable command status")
    func itemLifecycleUpdatesObservableCommandStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-lifecycle"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-command-lifecycle",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-lifecycle"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle",
                startedAtMs: 1_782_900_000_000,
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )

        #expect(await changes.itemInserted(id: "command-1") != nil)
        let commandItem = try #require(chat.items.first { $0.itemID == "command-1" })
        guard case .command(let startedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(startedCommand.status == .inProgress)
        #expect(startedCommand.startedAt != nil)

        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle",
                itemID: "command-1",
                delta: "done"
            )
        )
        #expect(await changes.itemUpdated(id: "command-1") != nil)
        guard case .command(let updatedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(updatedCommand.status == .inProgress)

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                lifecycle: .completed,
                threadID: "thread-command-lifecycle",
                turnID: "turn-command-lifecycle",
                completedAtMs: 1_782_900_001_000,
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "/bin/zsh -lc",
                    output: "done",
                    exitCode: 0,
                    status: "running"
                )
            )
        )
        #expect(await changes.itemUpdated(id: "command-1") != nil)
        guard case .command(let completedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(completedCommand.status == .completed)
        #expect(completedCommand.completedAt != nil)
    }

    @Test("thread inactive status never synthesizes turn or item completion")
    func threadInactiveStatusNeverSynthesizesTurnOrItemCompletion() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-status-terminal"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-command-status-terminal",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-status-terminal"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-status-terminal",
                turnID: "turn-command-status-terminal"
            )
        )
        let startedAt = Date().addingTimeInterval(-45)
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-command-status-terminal",
                turnID: "turn-command-status-terminal",
                startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1_000).rounded()),
                item: .init(
                    id: "command-status-terminal",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )

        #expect(await changes.itemInserted(id: "command-status-terminal") != nil)
        let commandItem = try #require(chat.items.first { $0.itemID == "command-status-terminal" })

        try await runtime.transport.emitServerNotification(
            method: "thread/status/changed",
            params: ThreadStatusParams(
                threadID: "thread-command-status-terminal",
                status: .init(type: "idle")
            )
        )

        #expect(await eventually {
            chat.status == .idle
                && chat.phase == .running(turnID: "turn-command-status-terminal")
        })
        guard case .command(let command) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(chat.turn(id: "turn-command-status-terminal")?.state == .inProgress)
        #expect(command.status == .inProgress)
        #expect(command.startedAt != nil)
        #expect(command.completedAt == nil)
        #expect(chat.phase == .running(turnID: "turn-command-status-terminal"))
        #expect(chat.status == .idle)
        withExtendedLifetime(changes) {}
    }

    @Test("turn completion does not become a command completion timestamp")
    func turnCompletionDoesNotBecomeCommandCompletionTimestamp() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-turn-completion"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-command-turn-completion",
            status: .idle,
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-turn-completion"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-turn-completion",
                turnID: "turn-command-turn-completion"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-command-turn-completion",
                turnID: "turn-command-turn-completion",
                startedAtMs: 1_782_900_000_000,
                item: .init(
                    id: "command-turn-completion",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )
        #expect(await changes.itemInserted(id: "command-turn-completion") != nil)

        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-command-turn-completion",
                turn: .init(
                    id: "turn-command-turn-completion",
                    status: "completed",
                    completedAt: 1_782_900_100
                )
            )
        )

        #expect(await eventually {
            chat.turn(id: "turn-command-turn-completion")?.state == .completed
        })
        let commandItem = try #require(chat.items.first {
            $0.itemID == "command-turn-completion"
        })
        guard case .command(let command) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(command.status == .completed)
        #expect(command.startedAt != nil)
        #expect(command.completedAt == nil)
        #expect(command.duration == nil)
        withExtendedLifetime(changes) {}
    }

    @Test("existing later turn content terminalizes command without inventing timing")
    func existingLaterTurnContentTerminalizesCommandWithoutInventingTiming()
        async throws
    {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-existing-progress"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-command-existing-progress", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-existing-progress"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress"
            )
        )
        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-command-existing-progress",
            turnID: "turn-command-existing-progress",
            itemID: "message-around-command"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress",
                itemID: "message-around-command",
                delta: "Before command"
            )
        )
        let startedAt = Date().addingTimeInterval(-45)
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress",
                startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1_000).rounded()),
                item: .init(
                    id: "command-existing-progress",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )
        #expect(await eventually {
            chat.items.contains { $0.itemID == "command-existing-progress" }
                && chat.items.contains { $0.itemID == "message-around-command" }
        })
        let commandItem = try #require(chat.items.first { $0.itemID == "command-existing-progress" })
        guard case .command(let startedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(startedCommand.status == .inProgress)

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-command-existing-progress",
                turnID: "turn-command-existing-progress",
                itemID: "message-around-command",
                delta: " after command"
            )
        )

        #expect(await eventually {
            guard case .command(let command) = commandItem.content else {
                return false
            }
            return command.status == .completed
                && command.startedAt != nil
                && command.completedAt == nil
                && command.duration == nil
                && chat.items.first { $0.itemID == "message-around-command" }?.text
                    == "Before command after command"
        })
        withExtendedLifetime(changes) {}
    }

    @Test("later turn content terminalizes command without inventing timing")
    func laterTurnContentTerminalizesCommandWithoutInventingTiming() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-progress"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-command-progress", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-progress"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-progress",
                turnID: "turn-command-progress"
            )
        )
        let startedAt = Date().addingTimeInterval(-45)
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-command-progress",
                turnID: "turn-command-progress",
                startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1_000).rounded()),
                item: .init(
                    id: "command-progress",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )
        #expect(await eventually {
            chat.items.contains { $0.itemID == "command-progress" }
        })
        let commandItem = try #require(chat.items.first { $0.itemID == "command-progress" })
        guard case .command(let startedCommand) = commandItem.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(startedCommand.status == .inProgress)

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-command-progress",
            turnID: "turn-command-progress",
            itemID: "message-after-command"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-command-progress",
                turnID: "turn-command-progress",
                itemID: "message-after-command",
                delta: "Next step"
            )
        )

        #expect(await eventually {
            guard case .command(let command) = commandItem.content else {
                return false
            }
            return command.status == .completed
                && command.startedAt != nil
                && command.completedAt == nil
                && command.duration == nil
                && chat.items.contains { $0.itemID == "message-after-command" }
        })
        withExtendedLifetime(changes) {}
    }

    @Test("late prior command update does not regress terminalized lifecycle items")
    func latePriorCommandUpdateDoesNotRegressTerminalizedLifecycleItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-command-late-update"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-command-late-update", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-command-late-update"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update",
                item: .init(
                    id: "command-first",
                    type: "commandExecution",
                    command: "git status"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update",
                item: .init(
                    id: "command-second",
                    type: "commandExecution",
                    command: "git diff"
                )
            )
        )

        #expect(await eventually {
            chat.items.contains { $0.itemID == "command-first" }
                && chat.items.contains { $0.itemID == "command-second" }
        })
        let firstCommand = try #require(chat.items.first { $0.itemID == "command-first" })
        let secondCommand = try #require(chat.items.first { $0.itemID == "command-second" })
        #expect(await eventually {
            guard case .command(let first) = firstCommand.content,
                case .command(let second) = secondCommand.content
            else {
                return false
            }
            return first.status == .completed && second.status == .inProgress
        })

        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-command-late-update",
                turnID: "turn-command-late-update",
                itemID: "command-first",
                delta: "late output"
            )
        )

        #expect(await eventually {
            guard case .command(let first) = firstCommand.content,
                case .command(let second) = secondCommand.content
            else {
                return false
            }
            return first.status == .completed
                && first.output == "late output"
                && second.status == .inProgress
        })
        withExtendedLifetime(changes) {}
    }

    @Test("chat observation refreshes a snapshot and applies live events in place")
    func chatObservationRefreshesSnapshotAndAppliesLiveEventsInPlace() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let completedAt = Date(timeIntervalSince1970: 4_000)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-live",
            turns: [
                .init(
                    id: "turn-existing",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Snapshot"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        let snapshotItem = try #require(chat.items.first)
        #expect(observation.chat === chat)
        #expect(chat.phase == .terminal(
            turnID: "turn-existing",
            disposition: .completed
        ))
        #expect(snapshotItem.text == "Snapshot")

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                lifecycle: .completed,
                threadID: "thread-live",
                turnID: "turn-existing",
                item: .init(
                    id: "message-existing",
                    type: "agentMessage",
                    text: "Snapshot updated",
                    phase: "final_answer"
                )
            )
        )
        #expect(await eventually { snapshotItem.text == "Snapshot updated" })
        #expect(chat.items.first === snapshotItem)

        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-live",
                turn: .init(id: "turn-existing", status: "completed")
            )
        )

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-live", turnID: "turn-live")
        )
        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-live",
            turnID: "turn-live",
            itemID: "message-live",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Hel",
                phase: "final_answer"
            )
        )
        #expect(await eventually {
            chat.items.contains { $0.itemID == "message-live" && $0.text == "Hel" }
        })
        let liveItem = try #require(chat.items.first { $0.itemID == "message-live" })

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "lo",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-live",
                turnID: "turn-live",
                tokenUsage: .init(
                    total: .init(inputTokens: 5, outputTokens: 7, totalTokens: 12),
                    modelContextWindow: 200_000
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-live", turn: .init(
                id: "turn-live",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        #expect(await eventually {
            chat.turns.contains { $0.id == "turn-live" && $0.status == .completed }
                && liveItem.text == "Hello"
                && chat.phase == .terminal(
                    turnID: "turn-live",
                    disposition: .completed
                )
        })
        let liveTurn = try #require(chat.turns.first { $0.id == "turn-live" })
        #expect(chat.items.first { $0.itemID == "message-live" } === liveItem)
        #expect(liveTurn.usage?.totalTokens == 12)
        #expect(liveTurn.usage?.modelContextWindow == 200_000)
        #expect(chat.updatedAt == completedAt)
        #expect(chat.transcript.finalAnswer == "Hello")
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        withExtendedLifetime(changes) {}

        observation.cancel()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-live",
            turns: [
                .init(
                    id: "turn-live",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-live",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-live",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Hello"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let restartedObservation = try await chat.observe()
        defer {
            restartedObservation.cancel()
        }

        #expect(await eventually {
            chat.items.first { $0.itemID == "message-live" }?.text == "Hello"
        })
        #expect(chat.items.filter { $0.itemID == "message-live" }.count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 2)
    }

    @Test("chat observation shares its pump and upgrades include-turn hydration")
    func chatObservationSharesPumpAndUpgradesIncludeTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-upgrade"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-upgrade"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-upgrade"))
        let metadataObservation = try await chat.observe(includeTurns: false)
        defer {
            metadataObservation.cancel()
        }

        #expect(chat.turn(id: "turn-history") == nil)

        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-upgrade",
            turns: [
                .init(
                    id: "turn-history",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-history",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-history",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Loaded from upgrade"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let turnObservation = try await chat.observe(includeTurns: true)
        defer {
            turnObservation.cancel()
        }

        let turn = try #require(chat.turn(id: "turn-history"))
        #expect(turn.status == .completed)
        #expect(chat.items(in: "turn-history").map(\.text) == ["Loaded from upgrade"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        let readRequests = await runtime.transport.recordedRequests(method: "thread/read")
        #expect(readRequests.count == 2)
        let firstParams = try readRequests[0].decodeParams(ThreadReadParams.self)
        let secondParams = try readRequests[1].decodeParams(ThreadReadParams.self)
        #expect(firstParams.includeTurns == false)
        #expect(secondParams.includeTurns == true)
    }

    @Test("include-turn join waits for in-flight observation start then upgrades once")
    func includeTurnJoinWaitsForStartThenUpgradesOnce() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let readGate = CodexAppServerTestGate()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-join-upgrade"))
        var metadataObservation: CodexChatObservation?
        var turnsObservation: CodexChatObservation?

        try await runtime.transport.enqueueThreadResume(.init(id: chat.id))
        try await runtime.transport.enqueueThreadRead(.init(id: chat.id, status: .idle))
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/read",
            gate: readGate
        )
        try await runtime.transport.enqueueThreadRead(.init(
            id: chat.id,
            status: .idle,
            turns: [.init(id: "turn-joined", state: .completed)]
        ))

        let metadataStart = Task { @MainActor in
            do { metadataObservation = try await chat.observe(includeTurns: false) }
            catch { Issue.record("Metadata observation failed: \(error)") }
        }
        await runtime.transport.waitForRequest(method: "thread/read", count: 1)
        let turnsJoin = Task { @MainActor in
            do { turnsObservation = try await chat.observe(includeTurns: true) }
            catch { Issue.record("Turns observation failed: \(error)") }
        }

        await readGate.open()
        await metadataStart.value
        await turnsJoin.value
        defer {
            metadataObservation?.cancel()
            turnsObservation?.cancel()
        }

        #expect(metadataObservation != nil)
        #expect(turnsObservation != nil)
        #expect(chat.turn(id: "turn-joined")?.status == .completed)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        let reads = await runtime.transport.recordedRequests(method: "thread/read")
        #expect(reads.count == 2)
        #expect(try reads.map { try $0.decodeParams(ThreadReadParams.self).includeTurns }
            == [false, true])
    }

    @Test("cancelling one observation start waiter preserves the shared start")
    func cancellingObservationStartWaiterPreservesSharedStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let readGate = CodexAppServerTestGate()
        let chat = context.model(for: CodexThreadID(rawValue: "thread-join-cancel"))

        try await runtime.transport.enqueueThreadResume(.init(id: chat.id))
        try await runtime.transport.enqueueThreadRead(.init(id: chat.id, status: .idle))
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/read",
            gate: readGate
        )

        var firstWasCancelled = false
        var secondObservation: CodexChatObservation?
        let firstStart = Task { @MainActor in
            do {
                _ = try await chat.observe(includeTurns: false)
                Issue.record("Expected the first observation waiter to be cancelled")
            } catch is CancellationError {
                firstWasCancelled = true
            } catch {
                Issue.record("Unexpected first observation failure: \(error)")
            }
        }
        await runtime.transport.waitForRequest(method: "thread/read")
        let secondStart = Task { @MainActor in
            do {
                secondObservation = try await chat.observe(includeTurns: false)
            } catch {
                Issue.record("Unexpected second observation failure: \(error)")
            }
        }
        await Task.yield()

        firstStart.cancel()
        await firstStart.value

        #expect(firstWasCancelled)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        await readGate.open()
        await secondStart.value
        let observation = try #require(secondObservation)
        defer { observation.cancel() }

        #expect(observation.chat === chat)
        #expect(chat.phase == .idle)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").count == 1)
    }

    @Test("finished chat observations are not reused")
    func finishedChatObservationsAreNotReused() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-finished"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-finished"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-finished"))
        let firstObservation = try await chat.observe()
        defer {
            firstObservation.cancel()
        }
        let firstChanges = ChatUpdateRecorder(stream: firstObservation.updates)

        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-finished")
        )
        #expect(await eventually { chat.status == .notLoaded && chat.phase == .idle })
        #expect(await eventually { firstChanges.isFinished })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-finished"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-finished",
            turns: [.init(id: "turn-restarted", state: .completed)]
        ))

        let restartedObservation = try await chat.observe()
        defer {
            restartedObservation.cancel()
        }
        let restartedChanges = ChatUpdateRecorder(stream: restartedObservation.updates)

        #expect(chat.turn(id: "turn-restarted") != nil)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 2)

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-finished",
            turnID: "turn-restarted",
            itemID: "message-restarted",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-finished",
                turnID: "turn-restarted",
                itemID: "message-restarted",
                delta: "Live after restart",
                phase: "final_answer"
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "message-restarted" }?.text == "Live after restart"
        })
        withExtendedLifetime(restartedChanges) {}
    }

    @Test("chat observation change streams finish when setup consumes terminal events")
    func chatObservationChangeStreamsFinishWhenSetupConsumesTerminalEvents() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-terminal-setup"))
        await runtime.transport.holdNext(method: "thread/read", gate: gate)
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-terminal-setup"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-terminal-setup"))
        var observedChat: CodexChatObservation?
        let observeTask = Task { @MainActor in
            observedChat = try await chat.observe()
        }

        await runtime.transport.waitForRequest(method: "thread/read")
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-terminal-setup")
        )
        await gate.open()

        try await observeTask.value
        let observation = try #require(observedChat)
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        #expect(observation.chat === chat)
        #expect(observation.chat.id == "thread-terminal-setup")
        #expect(await eventually { changes.isFinished })
    }

    @Test("chat observation keeps refreshed output snapshots idempotent with replayed deltas")
    func chatObservationKeepsRefreshedOutputSnapshotsIdempotentWithReplayedDeltas() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-replay",
                turnID: "turn-replay",
                item: .init(
                    id: "command-replay",
                    type: "commandExecution",
                    command: "echo hello",
                    output: ""
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-replay",
                turnID: "turn-replay",
                itemID: "command-replay",
                delta: "Hel"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-replay",
                turnID: "turn-replay",
                itemID: "command-replay",
                delta: "lo"
            )
        )
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-replay"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-replay",
            turns: [
                .init(
                    id: "turn-replay",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "command-replay",
                            kind: .commandExecution,
                            content: .command(.init(command: "echo hello", output: "Hello"))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-replay"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        try? await Task.sleep(for: .milliseconds(100))

        #expect(chat.items.first { $0.itemID == "command-replay" }?.text == "Hello")
        #expect(chat.items.filter { $0.itemID == "command-replay" }.count == 1)
    }

    @Test("chat observation keeps refreshed message snapshots idempotent with buffered replayed deltas")
    func chatObservationKeepsRefreshedMessageSnapshotsIdempotentWithBufferedReplayedDeltas() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let gate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-message-replay"))
        await runtime.transport.holdNext(method: "thread/read", gate: gate)
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-message-replay",
            turns: [
                .init(
                    id: "turn-message-replay",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "message-replay",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-replay",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Hello"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-message-replay"))
        var observedChat: CodexChatObservation?
        let observeTask = Task { @MainActor in
            observedChat = try await chat.observe()
        }
        await runtime.transport.waitForRequest(method: "thread/read")

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-message-replay",
            turnID: "turn-message-replay",
            itemID: "message-replay",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-message-replay",
                turnID: "turn-message-replay",
                itemID: "message-replay",
                delta: "Hel",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-message-replay",
                turnID: "turn-message-replay",
                itemID: "message-replay",
                delta: "lo",
                phase: "final_answer"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-message-replay",
                turnID: "turn-message-replay",
                itemID: "message-replay",
                delta: " world",
                phase: "final_answer"
            )
        )
        await gate.open()

        try await observeTask.value
        let observation = try #require(observedChat)
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        #expect(await eventually {
            chat.items.first { $0.itemID == "message-replay" }?.text == "Hello world"
        })
        #expect(chat.items.filter { $0.itemID == "message-replay" }.count == 1)
        withExtendedLifetime(changes) {}
    }

    @Test("duplicate chat observations create independent subscriber leases")
    func duplicateChatObservationsCreateIndependentLeases() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-duplicate"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-duplicate"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-duplicate"))
        let firstObservation = try await chat.observe()
        defer {
            firstObservation.cancel()
        }

        let secondObservation = try await chat.observe()
        defer { secondObservation.cancel() }
        #expect(secondObservation !== firstObservation)
        #expect(secondObservation.chat === chat)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test("chat observation preserves distinct repeated narrative snapshot items")
    func chatObservationPreservesDistinctRepeatedNarrativeSnapshotItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-duplicate-history"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-duplicate-history",
            turns: [
                .init(
                    id: "turn-duplicate-history",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "review-a",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "user-a",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-a",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "answer-a",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "answer-a",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "OK"
                            ))
                        ),
                        .init(
                            id: "reasoning-a",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "command-a",
                            kind: .commandExecution,
                            content: .command(.init(command: "/bin/zsh -lc"))
                        ),
                        .init(
                            id: "user-b",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-b",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "answer-b",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "answer-b",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "OK"
                            ))
                        ),
                        .init(
                            id: "reasoning-b",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "command-b",
                            kind: .commandExecution,
                            content: .command(.init(command: "/bin/zsh -lc"))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-duplicate-history"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        #expect(chat.items.map(\.itemID) == [
            "review-a",
            "user-a",
            "answer-a",
            "reasoning-a",
            "command-a",
            "user-b",
            "answer-b",
            "reasoning-b",
            "command-b",
        ])
    }

    @Test("chat observation preserves replay narrative snapshot items across turns")
    func chatObservationPreservesReplayNarrativeSnapshotItemsAcrossTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-replay-history"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-replay-history",
            turns: [
                .init(
                    id: "turn-replay-a",
                    state: .completed,
                    items: [
                        .init(
                            id: "review-a",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "user-a",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-a",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "reasoning-a",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "answer-a",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "answer-a",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Same final answer"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-replay-b",
                    state: .completed,
                    items: [
                        .init(
                            id: "review-b",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "user-b",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "user-b",
                                role: .user,
                                text: "Review current changes"
                            ))
                        ),
                        .init(
                            id: "reasoning-b",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: "Checking diff"))
                        ),
                        .init(
                            id: "answer-b",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "answer-b",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Same final answer"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-replay-c",
                    state: .completed,
                    items: [
                        .init(
                            id: "reasoning-c",
                            kind: .reasoning,
                            content: .reasoning(.init(
                                summary: ["Checking diff"],
                                content: ["Distinct raw trace"]
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-replay-history"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        #expect(chat.items.map(\.itemID) == [
            "review-a",
            "user-a",
            "reasoning-a",
            "answer-a",
            "review-b",
            "user-b",
            "reasoning-b",
            "answer-b",
            "reasoning-c",
        ])
    }

    @Test("chat observation preserves replay narrative live items across turns")
    func chatObservationPreservesReplayNarrativeLiveItemsAcrossTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-replay-live"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-replay-live", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-replay-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        for turnID in ["turn-replay-a", "turn-replay-b"] {
            try await runtime.transport.emitServerNotification(
                method: "turn/started",
                params: TurnStartedParams(
                    threadID: "thread-replay-live",
                    turnID: turnID
                )
            )
            try await runtime.transport.emitServerNotification(
                method: "item/started",
                params: ThreadItemParams(
                    lifecycle: .started,
                    threadID: "thread-replay-live",
                    turnID: turnID,
                    item: .init(
                        id: "reasoning-\(turnID)",
                        type: "reasoning",
                        text: "Checking diff"
                    )
                )
            )
            try await runtime.transport.emitServerNotification(
                method: "item/started",
                params: ThreadItemParams(
                    lifecycle: .started,
                    threadID: "thread-replay-live",
                    turnID: turnID,
                    item: .init(
                        id: "diagnostic-\(turnID)",
                        type: "agentMessage",
                        text: "Review was interrupted."
                    )
                )
            )
            #expect(await eventually {
                chat.items.contains { $0.itemID == "reasoning-\(turnID)" }
                    && chat.items.contains { $0.itemID == "diagnostic-\(turnID)" }
            })
            try await runtime.transport.emitServerNotification(
                method: "turn/completed",
                params: TurnCompletedParams(
                    threadID: "thread-replay-live",
                    turn: .init(id: turnID, status: "completed")
                )
            )
        }

        #expect(await eventually {
            chat.items.map(\.itemID) == [
                "reasoning-turn-replay-a",
                "diagnostic-turn-replay-a",
                "reasoning-turn-replay-b",
                "diagnostic-turn-replay-b",
            ]
        })
        withExtendedLifetime(changes) {}
    }

    @Test("chat observation removes reasoning parts only within the same turn")
    func chatObservationRemovesReasoningPartsOnlyWithinSameTurn() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-reasoning-parts"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-reasoning-parts", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-reasoning-parts"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-reasoning-parts", turnID: "turn-a")
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-reasoning-parts",
                turnID: "turn-a",
                item: .init(
                    id: "reasoning-parent:summary:0",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        #expect(await eventually {
            chat.items.contains {
                $0.turnID == "turn-a" && $0.itemID == "reasoning-parent:summary:0"
            }
        })
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-reasoning-parts",
                turn: .init(id: "turn-a", status: "completed")
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-reasoning-parts", turnID: "turn-b")
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-reasoning-parts",
                turnID: "turn-b",
                item: .init(
                    id: "reasoning-parent:summary:0",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-reasoning-parts",
                turnID: "turn-b",
                item: .init(
                    id: "reasoning-parent",
                    type: "reasoning",
                    text: "Checked diff"
                )
            )
        )

        #expect(await eventually {
            chat.items.map { "\($0.turnID?.rawValue ?? "nil"):\($0.itemID)" } == [
                "turn-a:reasoning-parent:summary:0",
                "turn-b:reasoning-parent",
            ]
        })
        guard case .itemRemoved(let removedItem) =
            await changes.itemRemoved(id: "reasoning-parent:summary:0")
        else {
            Issue.record("Expected reasoning part removal.")
            return
        }
        #expect(removedItem.id == "reasoning-parent:summary:0")
        #expect(removedItem.kind == .reasoning)
        #expect(removedItem.turnID == "turn-b")
    }

    @Test("chat observation preserves distinct repeated narrative live items")
    func chatObservationPreservesDistinctRepeatedNarrativeLiveItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-duplicate-live"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-duplicate-live", turns: []))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-duplicate-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "review-a",
                    type: "enteredReviewMode",
                    text: "current changes"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "diagnostic-a",
                    type: "agentMessage",
                    text: "Repeated diagnostic"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "reasoning-a",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "diagnostic-b",
                    type: "agentMessage",
                    text: "Repeated diagnostic"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "command-a",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "reasoning-b",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-duplicate-live",
                turnID: "turn-duplicate-live",
                item: .init(
                    id: "command-b",
                    type: "commandExecution",
                    command: "/bin/zsh -lc"
                )
            )
        )

        let expectedItemIDs = [
            "review-a",
            "reasoning-a",
            "diagnostic-a",
            "command-a",
            "reasoning-b",
            "diagnostic-b",
            "command-b",
        ]
        #expect(await eventually {
            chat.items.count >= expectedItemIDs.count
        })
        #expect(chat.items.count == expectedItemIDs.count)
        #expect(Set(chat.items.map(\.itemID)) == Set(expectedItemIDs))
        withExtendedLifetime(changes) {}
    }

    @Test("chat observations stream snapshots and item text changes")
    func chatObservationsStreamSnapshotsAndItemTextChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-changes"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-changes",
            turns: [
                .init(
                    id: "turn-existing",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                phase: .finalAnswer,
                                text: "Snapshot"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-changes"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        #expect(observation.chat === chat)
        #expect(chat.items.map(\.text) == ["Snapshot"])

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-changes",
            turnID: "turn-live",
            itemID: "message-live",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-changes",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Hel",
                phase: "final_answer"
            )
        )

        let insertedChange = await changes.itemInserted(id: "message-live")
        #expect(insertedChange != nil)
        let initialTextChange = await changes.itemTextAppended(
            id: "message-live",
            delta: "Hel"
        )
        #expect(initialTextChange != nil)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Hel")

        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-changes",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "lo",
                phase: "final_answer"
            )
        )

        guard case .itemTextAppended(let item, let delta) =
            await changes.itemTextAppended(id: "message-live", delta: "lo")
        else {
            Issue.record("Expected appended text change.")
            return
        }
        #expect(item.id == "message-live")
        #expect(item.kind == .agentMessage)
        #expect(item.turnID == "turn-live")
        #expect(delta == "lo")
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Hello")

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                lifecycle: .completed,
                threadID: "thread-changes",
                turnID: "turn-live",
                item: .init(
                    id: "message-live",
                    type: "agentMessage",
                    text: "Rewritten",
                    phase: "final_answer"
                )
            )
        )

        let updatedChange = await changes.itemUpdated(id: "message-live")
        #expect(updatedChange != nil)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Rewritten")
    }

    @Test("chat item identity preserves kind changes from baseline to live updates")
    func chatItemIdentityPreservesKindChangesFromBaselineToLiveUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        let chat = context.model(for: CodexThreadID(rawValue: "thread-kind-change"))
        chat.apply(
            CodexThreadSnapshot(
                id: chat.id,
                turns: [
                    .init(
                        id: "turn-kind-change",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "item-kind-change",
                                kind: .unknown("progress"),
                                content: .diagnostic("Initial")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )
        let originalItem = try #require(chat.items.first)

        let changes = chat.apply(CodexThreadEvent.itemUpdated(
            .init(
                id: "item-kind-change",
                kind: .diagnostic,
                content: .diagnostic("Updated")
            ),
            turnID: "turn-kind-change"
        ))

        #expect(chat.items.count == 2)
        let originalItems = chat.items.filter {
            $0.kind == .unknown("progress") && $0.text == "Initial"
        }
        let diagnosticItems = chat.items.filter {
            $0.kind == .diagnostic && $0.text == "Updated"
        }
        #expect(originalItems.count == 1)
        #expect(originalItems.first === originalItem)
        #expect(diagnosticItems.count == 1)
        let diagnosticItem = try #require(diagnosticItems.first)
        #expect(changes.contains(.itemInserted(
            id: diagnosticItem.id,
            turnID: "turn-kind-change"
        )))
    }

    @Test("tool call progress updates preserve existing metadata")
    func toolCallProgressUpdatesPreserveExistingMetadata() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-tool-progress"))
        chat.apply(
            CodexThreadSnapshot(
                id: chat.id,
                turns: [
                    .init(
                        id: "turn-tool-progress",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "tool-progress",
                                kind: .mcpToolCall,
                                content: .toolCall(.init(
                                    namespace: "mcp",
                                    server: "github",
                                    name: "search_issues",
                                    arguments: #"{"q":"is:open"}"#,
                                    status: .inProgress
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )
        let toolItem = try #require(chat.items.first { $0.itemID == "tool-progress" })

        let changes = chat.apply(CodexThreadEvent.itemUpdated(
            .init(
                id: "tool-progress",
                kind: .mcpToolCall,
                content: .toolCall(.init(result: "Searching GitHub"))
            ),
            turnID: "turn-tool-progress"
        ))

        #expect(changes.contains(.itemUpdated(
            id: toolItem.id,
            turnID: "turn-tool-progress"
        )))
        guard case .toolCall(let toolCall) = toolItem.content else {
            Issue.record("Expected tool call item")
            return
        }
        #expect(toolCall.namespace == "mcp")
        #expect(toolCall.server == "github")
        #expect(toolCall.name == "search_issues")
        #expect(toolCall.arguments == #"{"q":"is:open"}"#)
        #expect(toolCall.result == "Searching GitHub")
        #expect(toolCall.status == .inProgress)
    }

    @Test("active chat refresh emits snapshots after phase reconciliation")
    func activeChatRefreshEmitsSnapshotsAfterPhaseReconciliation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-stream"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-stream",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-running", state: .inProgress)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-stream"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        #expect(chat.phase == .running(turnID: "turn-running"))

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-stream"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-stream",
            status: .idle,
            turns: []
        ))

        try await context.refresh(chat)

        #expect(await changes.snapshot(reason: .refresh) != nil)
        #expect(chat.phase == .idle)
    }

    @Test("active chat refresh preserves live-streamed items omitted by lagging snapshots")
    func activeChatRefreshPreservesLiveStreamedItemsOmittedByLaggingSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-live",
            status: .active(activeFlags: []),
            turns: [
                .init(
                    id: "turn-existing",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                text: "Snapshot baseline"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-live"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-refresh-live",
            turnID: "turn-live",
            itemID: "message-live",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live update",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        let liveItem = try #require(chat.items.first { $0.itemID == "message-live" })

        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-existing",
                state: .inProgress,
                items: [
                    .init(
                        id: "message-existing",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-existing",
                            role: .assistant,
                            text: "Snapshot baseline"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-live",
            status: .active(activeFlags: [])
        ))

        try await context.refresh(chat)

        #expect(chat.items.first { $0.itemID == "message-live" } === liveItem)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Live update")
        #expect(chat.turns.contains { $0.id == "turn-live" })
    }

    @Test("active chat refresh preserves replay reasoning across turns")
    func activeChatRefreshPreservesReplayReasoningAcrossTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-replay"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-replay",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-replay"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-refresh-replay",
                turnID: "turn-live",
                item: .init(
                    id: "reasoning-live",
                    type: "reasoning",
                    text: "Checking diff"
                )
            )
        )
        #expect(await changes.itemInserted(id: "reasoning-live") != nil)

        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-snapshot",
                state: .inProgress,
                items: [
                    .init(
                        id: "reasoning-snapshot",
                        kind: .reasoning,
                        content: .reasoning(.init(summary: "Checking diff"))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-replay",
            status: .active(activeFlags: [])
        ))

        try await context.refresh(chat)

        #expect(chat.items.map(\.itemID) == ["reasoning-live", "reasoning-snapshot"])
        #expect(chat.turns.contains { $0.id == "turn-live" })
        #expect(chat.turns.contains { $0.id == "turn-snapshot" })
    }

    @Test("terminal chat refresh replaces live-streamed items with authoritative snapshot")
    func terminalChatRefreshReplacesLiveStreamedItemsWithAuthoritativeSnapshot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-terminal"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-terminal",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-terminal"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-refresh-terminal",
            turnID: "turn-live",
            itemID: "message-live",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-terminal",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live duplicate",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        #expect(chat.items.map(\.itemID) == ["message-live"])

        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-authoritative",
                state: .completed,
                items: [
                    .init(
                        id: "message-authoritative",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-authoritative",
                            role: .assistant,
                            text: "Authoritative"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-terminal",
            status: .idle
        ))

        try await context.refresh(chat)

        #expect(chat.turns.map(\.id.rawValue) == ["turn-authoritative"])
        #expect(chat.items.map(\.itemID) == ["message-authoritative"])
        #expect(chat.items.map(\.text) == ["Authoritative"])
    }

    @Test("terminal snapshot does not invent per-command completion timestamps")
    func terminalSnapshotDoesNotInventPerCommandCompletionTimestamps() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID: CodexThreadID = "thread-terminal-command-timestamps"

        try await runtime.transport.enqueueThreadResume(.init(id: threadID))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-terminal-command-timestamps",
                state: .completed,
                items: [
                    .init(
                        id: "command-early",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "first",
                            startedAt: Date(timeIntervalSince1970: 4_000)
                        ))
                    ),
                    .init(
                        id: "command-late",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "second",
                            startedAt: Date(timeIntervalSince1970: 4_500)
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: threadID,
            updatedAt: Date(timeIntervalSince1970: 5_000),
            status: .idle
        ))

        let chat = context.model(for: threadID)
        try await context.refresh(chat)

        #expect(chat.items.count == 2)
        for item in chat.items {
            guard case .command(let command) = item.content else {
                Issue.record("Expected command item")
                continue
            }
            #expect(command.status == .completed)
            #expect(command.completedAt == nil)
            #expect(command.duration == nil)
        }
    }

    @Test("later snapshot content terminalizes a command without inventing timing")
    func laterSnapshotContentTerminalizesCommandWithoutInventingTiming() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID: CodexThreadID = "thread-active-command-timestamps"

        try await runtime.transport.enqueueThreadResume(.init(id: threadID))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-active-command-timestamps",
                state: .inProgress,
                items: [
                    .init(
                        id: "command-before-message",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "git status",
                            status: .inProgress,
                            startedAt: Date(timeIntervalSince1970: 4_000)
                        ))
                    ),
                    .init(
                        id: "message-after-command",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-after-command",
                            role: .assistant,
                            text: "Done"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: threadID,
            updatedAt: Date(timeIntervalSince1970: 5_000),
            status: .active(activeFlags: [])
        ))

        let chat = context.model(for: threadID)
        try await context.refresh(chat)

        let item = try #require(chat.items.first {
            $0.itemID == "command-before-message"
        })
        guard case .command(let command) = item.content else {
            Issue.record("Expected command item")
            return
        }
        #expect(chat.turn(id: "turn-active-command-timestamps")?.state == .inProgress)
        #expect(command.status == .completed)
        #expect(command.startedAt == nil)
        #expect(command.completedAt == nil)
        #expect(command.duration == nil)
    }

    @Test("snapshot item order preserves interrupted and failed turn dispositions")
    func snapshotItemOrderPreservesTerminalTurnDispositions() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID: CodexThreadID = "thread-terminal-command-dispositions"

        func items(commandID: String, messageID: String) -> [CodexThreadItem] {
            [
                .init(
                    id: commandID,
                    kind: .commandExecution,
                    content: .command(.init(
                        command: "git status",
                        status: .inProgress
                    ))
                ),
                .init(
                    id: messageID,
                    kind: .agentMessage,
                    content: .message(.init(
                        id: messageID,
                        role: .assistant,
                        text: "Stopped"
                    ))
                ),
            ]
        }

        try await runtime.transport.enqueueThreadResume(.init(id: threadID))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-interrupted-command",
                state: .interrupted,
                items: items(
                    commandID: "command-interrupted",
                    messageID: "message-interrupted"
                )
            ),
            .init(
                id: "turn-failed-command",
                state: .failed(.init(message: "failed")),
                items: items(
                    commandID: "command-failed",
                    messageID: "message-failed"
                )
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: threadID,
            status: .idle
        ))

        let chat = context.model(for: threadID)
        try await context.refresh(chat)

        let interruptedItem = try #require(chat.items.first {
            $0.itemID == "command-interrupted"
        })
        let failedItem = try #require(chat.items.first {
            $0.itemID == "command-failed"
        })
        guard case .command(let interruptedCommand) = interruptedItem.content,
            case .command(let failedCommand) = failedItem.content
        else {
            Issue.record("Expected command items")
            return
        }
        #expect(interruptedCommand.status == .interrupted)
        #expect(failedCommand.status == .failed)
        #expect(interruptedCommand.duration == nil)
        #expect(failedCommand.duration == nil)
    }

    @Test("not-loaded metadata refresh replaces live-streamed items with authoritative turns")
    func notLoadedMetadataRefreshReplacesLiveStreamedItemsWithAuthoritativeTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-not-loaded"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-not-loaded",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-not-loaded"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-refresh-not-loaded",
            turnID: "turn-live",
            itemID: "message-live",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-not-loaded",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live duplicate",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        #expect(chat.items.map(\.itemID) == ["message-live"])

        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-authoritative",
                state: .completed,
                items: [
                    .init(
                        id: "message-authoritative",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-authoritative",
                            role: .assistant,
                            text: "Authoritative interruption"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-not-loaded",
            status: .notLoaded
        ))

        try await context.refresh(chat)

        #expect(chat.status == .notLoaded)
        #expect(chat.turns.map(\.id.rawValue) == ["turn-authoritative"])
        #expect(chat.items.map(\.itemID) == ["message-authoritative"])
        #expect(chat.items.map(\.text) == ["Authoritative interruption"])
    }

    @Test("mixed snapshot merge removes stale full turn items")
    func mixedSnapshotMergeRemovesStaleFullTurnItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = context.model(for: CodexThreadID(rawValue: "thread-mixed-snapshot-stale-items"))
        let fullTurnID = CodexTurnID(rawValue: "turn-full")
        let summaryTurnID = CodexTurnID(rawValue: "turn-summary")
        func messageItem(_ id: String, text: String) -> CodexThreadItem {
            CodexThreadItem(
                id: id,
                kind: .agentMessage,
                content: .message(.init(id: id, role: .assistant, text: text))
            )
        }

        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: fullTurnID,
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            messageItem("message-kept", text: "Keep me"),
                            messageItem("message-stale", text: "Remove me"),
                        ]
                    ),
                    .init(
                        id: summaryTurnID,
                        state: .inProgress,
                        itemsLoadState: .summary,
                        items: []
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )
        #expect(chat.items.map(\.itemID) == ["message-kept", "message-stale"])

        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: fullTurnID,
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            messageItem("message-kept", text: "Still here"),
                        ]
                    ),
                    .init(
                        id: summaryTurnID,
                        state: .inProgress,
                        itemsLoadState: .summary,
                        items: []
                    ),
                ]
            ),
            workspace: Optional<CodexWorkspace>.none
        )

        #expect(chat.items.map(\.itemID) == ["message-kept"])
        #expect(chat.items.first?.text == "Still here")
        #expect(chat.turns.map(\.id) == [fullTurnID, summaryTurnID])
    }

    @Test("not-loaded metadata fallback preserves live-streamed items omitted by turns")
    func notLoadedMetadataFallbackPreservesLiveStreamedItemsOmittedByTurns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-not-loaded-fallback"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-refresh-not-loaded-fallback",
            status: .active(activeFlags: []),
            turns: []
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-not-loaded-fallback"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-refresh-not-loaded-fallback",
                turnID: "turn-live"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-refresh-not-loaded-fallback",
                turnID: "turn-live",
                item: .init(
                    id: "command-live",
                    type: "commandExecution",
                    command: "/bin/zsh -lc 'git status --short'"
                )
            )
        )
        #expect(await changes.itemInserted(id: "command-live") != nil)
        let liveCommand = try #require(chat.items.first { $0.itemID == "command-live" })

        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-summary",
                state: .interrupted,
                items: [
                    .init(
                        id: "message-interrupted",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-interrupted",
                            role: .assistant,
                            text: "Review was interrupted."
                        ))
                    ),
                ]
            ),
        ]))
        await runtime.transport.enqueueFailure(
            code: -32_004,
            message: "thread not loaded: thread-refresh-not-loaded-fallback",
            for: "thread/read"
        )

        try await context.refresh(chat)

        #expect(chat.status == .notLoaded)
        #expect(chat.items.first { $0.itemID == "command-live" } === liveCommand)
        #expect(chat.items.first { $0.itemID == "message-interrupted" }?.text == "Review was interrupted.")
        #expect(chat.items.map(\.itemID).contains("command-live"))
        #expect(chat.items.map(\.itemID).contains("message-interrupted"))
    }

    @Test("restarted chat observation preserves prior live-streamed items omitted by lagging snapshots")
    func restartedChatObservationPreservesPriorLiveStreamedItemsOmittedByLaggingSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-reobserve-live"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-reobserve-live",
            status: .active(activeFlags: []),
            turns: [
                .init(
                    id: "turn-existing",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "message-existing",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-existing",
                                role: .assistant,
                                text: "Snapshot baseline"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-reobserve-live"))
        let observation = try await chat.observe()
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-reobserve-live",
            turnID: "turn-live",
            itemID: "message-live",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-reobserve-live",
                turnID: "turn-live",
                itemID: "message-live",
                delta: "Live update",
                phase: "final_answer"
            )
        )
        #expect(await changes.itemInserted(id: "message-live") != nil)
        let liveItem = try #require(chat.items.first { $0.itemID == "message-live" })
        let liveTurn = try #require(chat.turn(id: "turn-live"))

        observation.cancel()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-reobserve-live"))
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-existing",
                state: .inProgress,
                items: [
                    .init(
                        id: "message-existing",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "message-existing",
                            role: .assistant,
                            text: "Snapshot baseline"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-reobserve-live",
            status: .active(activeFlags: [])
        ))

        let restartedObservation = try await chat.observe()
        defer {
            restartedObservation.cancel()
        }

        #expect(chat.items.first { $0.itemID == "message-live" } === liveItem)
        #expect(chat.items.first { $0.itemID == "message-live" }?.text == "Live update")
        #expect(chat.turn(id: "turn-live") === liveTurn)
        #expect(chat.items.map(\.itemID).filter { $0 == "message-live" }.count == 1)
    }

    @Test("active chat refresh applies buffered live events after read failure")
    func activeChatRefreshAppliesBufferedLiveEventsAfterReadFailure() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-failure"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-refresh-failure"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-refresh-failure"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-refresh-failure"))
        await runtime.transport.holdNext(method: "thread/read", gate: gate)
        await runtime.transport.enqueueFailure(
            code: -32000,
            message: "read failed",
            for: "thread/read"
        )

        let refreshTask = Task {
            try await context.refresh(chat)
        }

        await runtime.transport.waitForRequest(method: "thread/read", count: 2)
        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-refresh-failure",
            turnID: "turn-buffered",
            itemID: "message-buffered",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-refresh-failure",
                turnID: "turn-buffered",
                itemID: "message-buffered",
                delta: "Buffered",
                phase: "final_answer"
            )
        )
        await gate.open()

        do {
            _ = try await refreshTask.value
            Issue.record("Expected refresh to throw.")
        } catch {
        }

        let inserted = await changes.itemInserted(id: "message-buffered")
        #expect(inserted != nil)
        #expect(chat.items.first { $0.itemID == "message-buffered" }?.text == "Buffered")
    }

    @Test("active chat observation owns one pump with independent streams")
    func activeChatObservationOwnsOnePumpWithIndependentStreams() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-shared-changes"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-shared-changes"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-shared-changes"))
        let firstObservation = try await chat.observe()
        defer {
            firstObservation.cancel()
        }
        #expect(firstObservation.chat === chat)

        let secondObservation = try await chat.observe()
        defer { secondObservation.cancel() }
        #expect(secondObservation !== firstObservation)
        #expect(secondObservation.chat === chat)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test("chat observation preserves loading phase for active thread snapshots")
    func chatObservationPreservesLoadingPhaseForActiveThreadSnapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-running"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-running",
            status: .active(activeFlags: []),
            turns: [.init(id: "turn-running", state: .inProgress)]
        ))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-running"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        #expect(chat.phase == .running(turnID: "turn-running"))
        #expect(chat.turn(id: "turn-running")?.status == .inProgress)
    }

    @Test("thread closed notifications preserve failed chat phase")
    func threadClosedNotificationsPreserveFailedChatPhase() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-failed"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-failed"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-failed"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-failed",
                turn: .init(
                    id: "turn-failed",
                    status: "failed",
                    error: .init(
                        message: "Tool failed",
                        codexErrorInfo: "serverOverloaded",
                        additionalDetails: "upstream detail"
                    )
                )
            )
        )

        #expect(await eventually {
            chat.phase == .terminal(turnID: "turn-failed", disposition: .failed)
        })
        #expect(chat.turn(id: "turn-failed")?.error == .init(
            message: "Tool failed",
            info: .serverOverloaded,
            additionalDetails: "upstream detail"
        ))

        try await runtime.transport.emitServerNotification(
            method: "thread/status/changed",
            params: ThreadStatusParams(threadID: "thread-failed", status: .init(type: "idle"))
        )
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-failed")
        )

        #expect(await eventually {
            chat.phase == .terminal(turnID: "turn-failed", disposition: .failed)
        })
        withExtendedLifetime(changes) {}
    }

    @Test("thread closed notifications clear active chat status")
    func threadClosedNotificationsClearActiveChatStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-closed-status"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-closed-status"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-closed-status"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "thread/status/changed",
            params: ThreadStatusParams(threadID: "thread-closed-status", status: .init(type: "active"))
        )
        #expect(await eventually {
            if case .active = chat.status {
                return true
            }
            return false
        })

        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-closed-status")
        )

        #expect(await eventually { chat.status == .notLoaded && chat.phase == .idle })
        withExtendedLifetime(changes) {}
    }

    @Test("live item output deltas accumulate until replacement arrives")
    func liveItemOutputDeltasAccumulateUntilReplacementArrives() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-output"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-output"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-output"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-output",
                turnID: "turn-output",
                item: .init(
                    id: "command-output",
                    type: "commandExecution",
                    command: "echo Hello",
                    output: ""
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-output",
                turnID: "turn-output",
                itemID: "command-output",
                delta: "Hel"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: OutputDeltaParams(
                threadID: "thread-output",
                turnID: "turn-output",
                itemID: "command-output",
                delta: "lo"
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "command-output" }?.text == "Hello"
        })

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                lifecycle: .completed,
                threadID: "thread-output",
                turnID: "turn-output",
                item: .init(
                    id: "command-output",
                    type: "commandExecution",
                    text: "Completed output",
                    phase: nil
                )
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "command-output" }?.text == "Completed output"
        })
        withExtendedLifetime(changes) {}
    }

    @Test("replacement file change updates do not append output")
    func replacementFileChangeUpdatesDoNotAppendOutput() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-patch-replacement"))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-patch-replacement"))

        let chat = context.model(for: CodexThreadID(rawValue: "thread-patch-replacement"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)
        func fileChangePath() -> String? {
            guard let item = chat.items.first(where: { $0.itemID == "file-patch" }),
                case .fileChange(let fileChange) = item.content
            else {
                return nil
            }
            return fileChange.path
        }

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-patch-replacement",
                turnID: "turn-patch-replacement",
                item: .init(
                    id: "file-patch",
                    type: "fileChange",
                    text: "Initial patch",
                    path: "Sources/File.swift"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: FileChangePatchUpdatedParams(
                threadID: "thread-patch-replacement",
                turnID: "turn-patch-replacement",
                itemID: "file-patch",
                displayText: "Patch one"
            )
        )
        #expect(await eventually {
            chat.items.first { $0.itemID == "file-patch" }?.text == "Patch one"
        })
        #expect(fileChangePath() == "Sources/File.swift")

        try await runtime.transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: FileChangePatchUpdatedParams(
                threadID: "thread-patch-replacement",
                turnID: "turn-patch-replacement",
                itemID: "file-patch",
                displayText: "Patch two"
            )
        )

        #expect(await eventually {
            chat.items.first { $0.itemID == "file-patch" }?.text == "Patch two"
        })
        #expect(fileChangePath() == "Sources/File.swift")
        withExtendedLifetime(changes) {}
    }

    @Test("chat send revalidates recent fetched results")
    func chatSendRevalidatesRecentFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-alpha", turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(alpha.updatedAt == completedAt)
        #expect(results.items.map(\.id.rawValue) == ["thread-alpha", "thread-beta"])
    }

    @Test("chat send moves the chat to the front of its workspace")
    func chatSendMovesChatToFrontOfWorkspace() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", workspace: workspaceURL, name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", workspace: workspaceURL, name: "Beta", updatedAt: secondUpdate),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })
        let workspace = try #require(alpha.workspace)
        #expect(workspace.chats.map(\.id.rawValue) == ["thread-beta", "thread-alpha"])

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-alpha", turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(workspace.chats.map(\.id.rawValue) == ["thread-alpha", "thread-beta"])
    }

    @Test("chat send refreshes primary recency-sorted fetched results")
    func chatSendRefreshesPrimaryRecencySortedFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
        ]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
        ))
        try await results.performFetch()
        let alpha = try #require(results.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
            .init(id: "thread-alpha", name: "Alpha", updatedAt: completedAt),
        ]))
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-alpha", turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(results.items.map(\.id.rawValue) == ["thread-beta", "thread-alpha"])
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 4)
    }

    @Test("chat send refreshes incomplete paged results for off-page updates")
    func chatSendRefreshesIncompletePagedResultsForOffPageUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstUpdate = Date(timeIntervalSince1970: 1_000)
        let secondUpdate = Date(timeIntervalSince1970: 2_000)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-alpha", name: "Alpha", updatedAt: firstUpdate),
            .init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate),
        ]))
        let allResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
        try await allResults.performFetch()
        let alpha = try #require(allResults.items.first { $0.id.rawValue == "thread-alpha" })

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-beta", name: "Beta", updatedAt: secondUpdate)],
            nextCursor: "next"
        ))
        let pagedResults = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindEqualityChatPredicate(.cli),
            sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
            fetchLimit: 1
        ))
        try await pagedResults.performFetch()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-alpha"))
        try await runtime.transport.enqueueTurnStart(turnID: "turn-alpha", status: "running")
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2,
            threads: [.init(id: "thread-alpha", name: "Alpha", updatedAt: completedAt)],
            nextCursor: "next"
        ))
        let sendTask = Task {
            try await alpha.send("hello")
        }

        await runtime.transport.waitForRequest(method: "turn/start")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-alpha", turn: .init(
                id: "turn-alpha",
                status: "completed",
                completedAt: Int(completedAt.timeIntervalSince1970)
            ))
        )

        _ = try await sendTask.value

        #expect(pagedResults.items.map(\.id.rawValue) == ["thread-alpha"])
    }

    @Test("workspace starts new chats through its model context")
    func workspaceStartsNewChatThroughContext() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .currentV2, threads: [
                .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
            ]))
        let workspaceResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-new", model: "gpt-5")

        let chat = try await workspace.startChat(.init(options: .init(model: "gpt-5")))

        #expect(chat.id == "thread-new")
        #expect(chat.workspace === workspace)
        #expect(workspace.chats.first === chat)

        let request = try #require(
            await runtime.transport.recordedRequests(method: "thread/start").first)
        let params = try request.decodeParams(ThreadStartParams.self)
        #expect(params.cwd == workspaceURL.path)
        #expect(params.model == "gpt-5")
    }

    @Test("model context starts reviews and inserts the active review chat into fetched results")
    func modelContextStartsReviewAndInsertsActiveChatIntoFetchedResults() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2,
            threads: [
                .init(
                    id: "thread-existing",
                    workspace: workspaceURL,
                    name: "Existing",
                    modelProvider: "openai",
                    recencyAt: Date(timeIntervalSince1970: 1_000)
                ),
            ],
            nextCursor: "server-next"
        ))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-review", reviewThreadID: "thread-review")
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                predicate: sourceKindEqualityChatPredicate(.cli),
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
            ))
        try await results.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                name: "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings.",
                recencyAt: Date(timeIntervalSince1970: 2_000)
            ),
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                modelProvider: "openai",
                recencyAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )

        #expect(results.items.first === started.chat)
        #expect(results.items.map(\.id.rawValue) == ["thread-review", "thread-existing"])
        #expect(started.chat.id == started.session.activeTurnThreadID)
        #expect(started.chat.workspace?.url.path == workspaceURL.path)
        #expect(started.chat.preview == "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings.")
        #expect(started.chat.title == started.chat.preview)

        let requests = await runtime.transport.recordedRequests().map(\.method)
        #expect(requests.contains("thread/start"))
        #expect(requests.contains("review/start"))
        #expect(requests.filter { $0 == "thread/list" }.count == 2)
    }

    @Test("started review seed does not truncate an existing chat transcript")
    func startedReviewSeedDoesNotTruncateExistingChatTranscript() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let existingChat = context.model(for: CodexThreadID(rawValue: "thread-review"))
        let existingSnapshot = CodexThreadSnapshot(
            id: "thread-review",
            workspace: workspaceURL,
            turns: [
                .init(
                    id: "turn-existing-user",
                    state: .completed,
                    itemsLoadState: .full,
                    items: [
                        .init(
                            id: "existing-user-message",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "existing-user-message",
                                role: .user,
                                text: "previous request"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "turn-existing-agent",
                    state: .completed,
                    itemsLoadState: .full,
                    items: [
                        .init(
                            id: "existing-agent-message",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "existing-agent-message",
                                role: .assistant,
                                text: "previous response"
                            ))
                        ),
                    ]
                ),
            ]
        )
        existingChat.apply(
            existingSnapshot,
            workspace: nil
        )

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-seed",
                state: .inProgress,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "turn-seed",
                        kind: .userMessage,
                        content: .message(.init(
                            id: "turn-seed",
                            role: .user,
                            text: "current changes"
                        ))
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )

        #expect(started.chat === existingChat)
        #expect(started.chat.turns.map(\.id.rawValue) == [
            "turn-existing-user",
            "turn-existing-agent",
            "turn-seed",
        ])
        #expect(started.chat.items.map(\.itemID) == [
            "existing-user-message",
            "existing-agent-message",
            "turn-seed",
        ])
        #expect(started.chat.items.map(\.text) == [
            "previous request",
            "previous response",
            "current changes",
        ])
    }

    @Test("model actor review start multicasts the active review to the main context")
    func modelActorReviewStartMulticastsActiveReviewToMainContext() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let container = CodexModelContainer(appServer: runtime.server)
        let mainContext = container.mainContext
        let actor = TestCodexModelActor(modelContainer: container)
        try await runtime.transport.enqueueUserVisibleThreadList(
            CodexAppServerTestThreadPage(threads: [])
        )
        let results = mainContext.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                predicate: archivedChatPredicate(false),
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
            ))
        try await results.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(id: "thread-review", workspace: workspaceURL, name: "Review")
        ]))

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "thread/resume should not be needed for a just-started review",
            for: "thread/resume"
        )
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let reviewChatID = try await actor.startReviewID(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )

        let mainChat = try #require(mainContext.registeredModel(for: reviewChatID))
        #expect(results.items.first === mainChat)
        #expect(results.items.map(\.id.rawValue) == ["thread-review"])
        #expect(mainChat.workspace?.url.path == workspaceURL.path)
        #expect(mainChat.items.map(\.text) == ["current changes"])

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )
        let observation = try await mainChat.observe()
        defer {
            observation.cancel()
        }
        #expect(mainChat.items.map(\.text) == ["current changes"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
    }

    @Test("started review chat survives temporary thread list omission")
    func startedReviewChatSurvivesTemporaryThreadListOmission() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                recencyAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        let results = context.fetchedResults(
            for: CodexFetchDescriptor<CodexChat>(
                predicate: archivedChatPredicate(false),
                sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)]
            ))
        try await results.performFetch()

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                recencyAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let reviewChat = started.chat
        let workspace = try #require(reviewChat.workspace)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(profile: .currentV2, threads: [
            .init(
                id: "thread-existing",
                workspace: workspaceURL,
                name: "Existing",
                recencyAt: Date(timeIntervalSince1970: 1_000)
            ),
        ]))

        try await results.performFetch()

        #expect(results.items.contains { $0 === reviewChat })
        #expect(results.items.map(\.id.rawValue) == ["thread-review", "thread-existing"])
        #expect(workspace.chats.contains { $0 === reviewChat })
        #expect(reviewChat.modelContext === context)
        #expect(context.registeredModel(for: reviewChat.id) === reviewChat)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 6)
    }

    @Test("started review observation reuses the live event thread without resuming")
    func startedReviewObservationReusesLiveEventThreadWithoutResuming() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "thread/resume should not be needed for a just-started review",
            for: "thread/resume"
        )
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-review",
                state: .inProgress,
                items: [
                    .init(
                        id: "turn-review",
                        kind: .enteredReviewMode,
                        content: .log("Review started")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-review",
            workspace: workspaceURL,
            name: "Review",
            modelProvider: "openai"
        ))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        #expect(started.chat.items.map(\.text) == ["Review started"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 1)
        withExtendedLifetime(changes) {}
    }

    @Test("started review consumes its prepared event thread across refresh before observation")
    func startedReviewConsumesPreparedEventThreadAcrossRefreshBeforeObservation() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-review",
            workspace: workspaceURL
        ))
        for text in ["Review started", "Review still running"] {
            try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
                .init(
                    id: "turn-review",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "turn-review",
                            kind: .enteredReviewMode,
                            content: .log(text)
                        ),
                    ]
                ),
            ]))
            try await runtime.transport.enqueueThreadRead(.init(
                id: "thread-review",
                workspace: workspaceURL,
                name: "Review",
                modelProvider: "openai"
            ))
        }

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        try await context.refresh(started.chat)
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.text) == ["Review still running"])
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 2)
    }

    @Test("started review observation survives empty rollout history reads")
    func startedReviewObservationSurvivesEmptyRolloutHistoryReads() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "thread/resume should not be needed for a just-started review",
            for: "thread/resume"
        )
        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.items.map(\.text) == ["current changes"])
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.text) == ["current changes"])
        #expect(started.chat.workspace?.url.path == workspaceURL.path)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").isEmpty)
        #expect(await runtime.transport.recordedRequests(method: "thread/turns/list").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "thread/read").count == 1)
    }

    @Test("started review observation replays prepared thread events received before observe")
    func startedReviewObservationReplaysPreparedThreadEventsReceivedBeforeObserve() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        try await emitAgentMessageStarted(
            on: runtime.transport,
            threadID: "thread-review",
            turnID: "turn-review",
            itemID: "message-before-observe",
            phase: "final_answer"
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-review",
                turnID: "turn-review",
                itemID: "message-before-observe",
                delta: "Buffered before observe",
                phase: "final_answer"
            )
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        #expect(await eventually {
            started.chat.items.first { $0.itemID == "message-before-observe" }?.text
                == "Buffered before observe"
        })
        withExtendedLifetime(changes) {}
    }

    @Test("started review observation skips prepared thread history covered by refresh")
    func startedReviewObservationSkipsPreparedThreadHistoryCoveredByRefresh() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-review",
                turnID: "turn-review"
            )
        )
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-review",
                state: .completed,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "final-message",
                        kind: .agentMessage,
                        content: .message(.init(
                            id: "final-message",
                            role: .assistant,
                            phase: .finalAnswer,
                            text: "Done"
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-review",
            workspace: workspaceURL,
            status: .idle
        ))

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try? await Task.sleep(for: .milliseconds(100))

        #expect(started.chat.turn(id: "turn-review")?.status == .completed)
        #expect(started.chat.phase == .terminal(
            turnID: "turn-review",
            disposition: .completed
        ))
        #expect(started.chat.items.map(\.itemID) == ["final-message"])
        withExtendedLifetime(changes) {}
    }

    @Test("started review ignores advisory subturn start after empty history read")
    func startedReviewIgnoresAdvisorySubturnStartAfterEmptyHistoryRead() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "rollout is empty",
            for: "thread/turns/list"
        )
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "includeTurns is unavailable before first user message",
            for: "thread/read"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.turns.map(\.id.rawValue) == ["turn-seed"])
        #expect(started.chat.items.map(\.text) == ["current changes"])

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }
        let changes = ChatUpdateRecorder(stream: observation.updates)

        try await runtime.transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-review",
                turnID: "turn-live"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ThreadItemParams(
                lifecycle: .started,
                threadID: "thread-review",
                turnID: "turn-seed",
                item: .init(
                    id: "review-mode",
                    type: "enteredReviewMode",
                    text: "current changes"
                )
            )
        )

        #expect(await eventually {
            started.chat.turns.map(\.id.rawValue) == ["turn-seed"]
                && started.chat.items.map(\.itemID) == ["turn-seed", "review-mode"]
                && started.chat.items.map(\.text) == ["current changes", "current changes"]
        })
        withExtendedLifetime(changes) {}
    }

    @Test("started review snapshot merge replaces provisional seed with authoritative review turn")
    func startedReviewSnapshotMergeReplacesProvisionalSeedWithAuthoritativeReviewTurn() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.turns.map(\.id.rawValue) == ["turn-seed"])
        #expect(started.chat.items.map(\.text) == ["current changes"])

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "turn-live",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "review-mode",
                                kind: .enteredReviewMode,
                                content: .log("current changes")
                            ),
                            .init(
                                id: "command-1",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc",
                                    status: .inProgress
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        #expect(started.chat.turns.map(\.id.rawValue) == ["turn-live"])
        #expect(started.chat.items.map(\.itemID) == ["review-mode", "command-1"])
        #expect(started.chat.items.map(\.text) == ["current changes", "/bin/zsh -lc"])
    }

    @Test("started review observation replaces response seed with authoritative turn list when available")
    func startedReviewObservationReplacesResponseSeedWithAuthoritativeTurnListWhenAvailable() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-review",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-review",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-review",
                state: .inProgress,
                items: [
                    .init(
                        id: "turn-review",
                        kind: .enteredReviewMode,
                        content: .log("Review started from live turn list")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review", workspace: workspaceURL))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.text) == ["Review started from live turn list"])
    }

    @Test("started review observation drops not-loaded response seed when full turn items arrive")
    func startedReviewObservationDropsNotLoadedSeedWhenFullTurnItemsArrive() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-review",
                state: .inProgress,
                itemsLoadState: .notLoaded,
                items: [
                    .init(
                        id: "seed-review",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-review",
                state: .inProgress,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                    .init(
                        id: "command-1",
                        kind: .commandExecution,
                        content: .command(.init(
                            command: "/bin/zsh -lc",
                            status: .inProgress
                        ))
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review", workspace: workspaceURL))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        #expect(started.chat.items.map(\.itemID) == ["seed-review"])

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.items.map(\.itemID) == ["review-mode", "command-1"])
        #expect(started.chat.items.map(\.text) == ["current changes", "/bin/zsh -lc"])
    }

    @Test("started review refresh replaces a marker when its raw identity changes")
    func startedReviewRefreshReplacesMarkerWhenRawIdentityChanges() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            .init(
                id: "turn-review",
                state: .inProgress,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "turn-review",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-review",
                state: .inProgress,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueThreadRead(.init(id: "thread-review", workspace: workspaceURL))

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        let seededItem = try #require(started.chat.items.first)
        #expect(seededItem.itemID == "turn-review")
        #expect(seededItem.id.rawValue == "turn-review:enteredReviewMode:turn-review")

        try await context.refresh(started.chat)

        let reviewMarkers = started.chat.items.filter { $0.kind == .enteredReviewMode }
        let refreshedItem = try #require(reviewMarkers.first)
        #expect(reviewMarkers.count == 1)
        #expect(refreshedItem !== seededItem)
        #expect(refreshedItem.itemID == "review-mode")
        #expect(refreshedItem.id.rawValue == "turn-review:enteredReviewMode:review-mode")
    }

    @Test("started review refresh coalesces running command snapshot replay")
    func startedReviewRefreshCoalescesRunningCommandSnapshotReplay() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let startedAt = Date(timeIntervalSince1970: 10)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        started.chat.apply(.itemStarted(
            .init(
                id: "live-command",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'git status --short'",
                    cwd: workspaceURL.path,
                    status: .inProgress,
                    startedAt: startedAt,
                    processID: "123",
                    source: .agent
                ))
            ),
            turnID: "turn-review"
        ))
        let seededCommand = try #require(
            started.chat.items.first { $0.kind == .commandExecution }
        )

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "turn-review",
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "snapshot-command",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc 'git status --short'",
                                    status: .inProgress
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        let commandItems = started.chat.items.filter { $0.kind == .commandExecution }
        let commandItem = try #require(commandItems.first)
        let command: CodexCommand
        switch commandItem.content {
        case .command(let value):
            command = value
        default:
            Issue.record("Expected a command item.")
            return
        }
        #expect(commandItems.count == 1)
        #expect(commandItem === seededCommand)
        #expect(commandItem.itemID == "snapshot-command")
        #expect(command.cwd == workspaceURL.path)
        #expect(command.startedAt == startedAt)
        #expect(command.processID == "123")
        #expect(command.source == .agent)
    }

    @Test("started review refresh moves running command replay into authoritative turn")
    func startedReviewRefreshMovesRunningCommandReplayIntoAuthoritativeTurn() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let startedAt = Date(timeIntervalSince1970: 10)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))
        _ = started.chat.apply(.itemStarted(
            .init(
                id: "call-live",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'git status --short'",
                    cwd: workspaceURL.path,
                    status: .inProgress,
                    startedAt: startedAt,
                    processID: "123",
                    source: .agent
                ))
            ),
            turnID: "turn-seed"
        ))
        _ = started.chat.apply(.turnStarted("turn-live"))
        let liveCommand = try #require(
            started.chat.items.first { $0.kind == .commandExecution }
        )
        #expect(liveCommand.turnID?.rawValue == "turn-seed")

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "turn-live",
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "call-live",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc 'git status --short'",
                                    cwd: workspaceURL.path,
                                    status: .inProgress,
                                    processID: "123",
                                    source: .agent
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        let commandItems = started.chat.items.filter { $0.kind == .commandExecution }
        let commandItem = try #require(commandItems.first)
        let command: CodexCommand
        switch commandItem.content {
        case .command(let value):
            command = value
        default:
            Issue.record("Expected a command item.")
            return
        }
        #expect(commandItems.count == 1)
        #expect(commandItem !== liveCommand)
        #expect(liveCommand.modelContext == nil)
        #expect(liveCommand.turnID == nil)
        #expect(commandItem.turnID?.rawValue == "turn-live")
        #expect(commandItem.itemID == "call-live")
        #expect(commandItem.id.rawValue == "turn-live:commandExecution:call-live")
        #expect(started.chat.items(in: "turn-seed").contains { $0.kind == .commandExecution } == false)
        #expect(started.chat.items(in: "turn-live").filter { $0.kind == .commandExecution }.count == 1)
        #expect(command.startedAt == startedAt)
        #expect(command.processID == "123")
        #expect(command.source == .agent)
    }

    @Test("started review sparse terminal refresh preserves live command log items")
    func startedReviewSparseTerminalRefreshPreservesLiveCommandLogItems() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-review"))
        _ = started.chat.apply(.itemStarted(
            .init(
                id: "review-start",
                kind: .enteredReviewMode,
                content: .log("Review started.")
            ),
            turnID: "turn-review"
        ))
        _ = started.chat.apply(.itemStarted(
            .init(
                id: "command-live",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'git status --short'",
                    cwd: workspaceURL.path,
                    output: " M Package.swift",
                    status: .completed,
                    source: .agent
                ))
            ),
            turnID: "turn-review"
        ))
        _ = started.chat.apply(.terminal(.completed(.init(
            turnID: "turn-review",
            completedAt: Date(timeIntervalSince1970: 10)
        ))))

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .idle,
                turns: [
                    .init(
                        id: "turn-review",
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "review-output",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace
        )

        #expect(started.chat.items(in: "turn-review").contains { $0.itemID == "command-live" })
        #expect(started.chat.items(in: "turn-review").contains { $0.kind == .exitedReviewMode })

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .idle,
                turns: []
            ),
            workspace: started.chat.workspace
        )

        #expect(started.chat.turn(id: "turn-review") == nil)
        #expect(started.chat.items(in: "turn-review").isEmpty)
    }

    @Test("started review refresh folds synthesized rollout turns into the live turn")
    func startedReviewRefreshFoldsSynthesizedRolloutTurnsIntoLiveTurn() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let startedAt = Date(timeIntervalSince1970: 10)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))
        _ = started.chat.apply(.itemStarted(
            .init(
                id: "reasoning-live",
                kind: .reasoning,
                content: .reasoning(.init(summary: "Reviewing differences"))
            ),
            turnID: "turn-seed"
        ))
        _ = started.chat.apply(.itemStarted(
            .init(
                id: "call-live",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'git status --short'",
                    cwd: workspaceURL.path,
                    status: .inProgress,
                    startedAt: startedAt,
                    processID: "123",
                    source: .agent
                ))
            ),
            turnID: "turn-seed"
        ))

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "turn-rollout",
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "user-real",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "user-real",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "reasoning-live",
                                kind: .reasoning,
                                content: .reasoning(.init(summary: "Reviewing differences"))
                            ),
                            .init(
                                id: "call-live",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc 'git status --short'",
                                    cwd: workspaceURL.path,
                                    status: .inProgress,
                                    processID: "123",
                                    source: .agent
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        #expect(started.chat.turns.contains { $0.id == "turn-rollout" } == false)
        #expect(started.chat.items.filter { $0.kind == .userMessage }.count == 1)
        #expect(started.chat.items.filter { $0.kind == .reasoning }.count == 1)
        let commandItems = started.chat.items.filter { $0.kind == .commandExecution }
        #expect(commandItems.count == 1)
        #expect(commandItems.first?.turnID?.rawValue == "turn-seed")

        _ = started.chat.apply(.itemCompleted(
            .init(
                id: "call-live",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'git status --short'",
                    cwd: workspaceURL.path,
                    status: .completed,
                    startedAt: startedAt,
                    processID: "123",
                    source: .agent
                ))
            ),
            turnID: "turn-seed"
        ))
        let completedCommand = try #require(
            started.chat.items.first { $0.kind == .commandExecution }
        )
        guard case .command(let completedValue) = completedCommand.content else {
            Issue.record("Expected a command item.")
            return
        }
        #expect(completedValue.status == .completed)
    }

    @Test("started review adopts rollout records with fully synthesized identities")
    func startedReviewAdoptsRolloutRecordsWithFullySynthesizedIdentities() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let startedAt = Date(timeIntervalSince1970: 10)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))

        // Early refresh: the rollout materializes the running review turn
        // under a synthesized turn id whose only item is the index-named user
        // message — no identity is shared with the seeded turn.
        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "rollout-read-1",
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "item-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "item-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )
        #expect(started.chat.turns.map(\.id) == ["turn-seed"])
        #expect(started.chat.items.filter { $0.kind == .userMessage }.count == 1)

        _ = started.chat.apply(.itemStarted(
            .init(
                id: "call-live",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'swift test'",
                    cwd: workspaceURL.path,
                    status: .inProgress,
                    startedAt: startedAt,
                    processID: "42",
                    source: .agent
                ))
            ),
            turnID: "turn-seed"
        ))

        // The next read regenerates the synthesized turn id.
        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "rollout-read-2",
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "item-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "item-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "item-2",
                                kind: .enteredReviewMode,
                                content: .log("current changes")
                            ),
                            .init(
                                id: "call-live",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc 'swift test'",
                                    cwd: workspaceURL.path,
                                    status: .inProgress,
                                    processID: "42",
                                    source: .agent
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )
        #expect(started.chat.turns.map(\.id) == ["turn-seed"])
        #expect(started.chat.items.filter { $0.kind == .userMessage }.count == 1)
        #expect(started.chat.items.filter { $0.kind == .commandExecution }.count == 1)

        _ = started.chat.apply(.itemCompleted(
            .init(
                id: "call-live",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/bin/zsh -lc 'swift test'",
                    cwd: workspaceURL.path,
                    status: .completed,
                    startedAt: startedAt,
                    processID: "42",
                    source: .agent
                ))
            ),
            turnID: "turn-seed"
        ))
        let liveCommand = try #require(
            started.chat.items.first { $0.kind == .commandExecution }
        )
        guard case .command(let liveValue) = liveCommand.content else {
            Issue.record("Expected a command item.")
            return
        }
        #expect(liveValue.status == .completed)

        // Once the rollout materializes a terminal reviewer turn, its
        // authoritative boundary must not be folded back into the still-open
        // seed merely because its synthesized identity has not been seen.
        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "rollout-exit",
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "item-2",
                                kind: .enteredReviewMode,
                                content: .log("current changes")
                            ),
                            .init(
                                id: "review-exit",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                    .init(
                        id: "rollout-activity",
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "call-after-exit",
                                kind: .commandExecution,
                                content: .command(.init(
                                    command: "/bin/zsh -lc 'git diff --check'",
                                    cwd: workspaceURL.path,
                                    exitCode: 0,
                                    status: .completed,
                                    source: .agent
                                ))
                            ),
                        ]
                    ),
                    .init(
                        id: "rollout-reviewer",
                        state: .interrupted,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "item-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "item-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "item-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "item-2",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "item-3",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "item-3",
                                    role: .assistant,
                                    text: "No issues found."
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        #expect(
            started.chat.turns.map(\.id)
                == ["turn-seed", "rollout-activity", "rollout-reviewer"]
        )
        #expect(started.chat.items(in: "rollout-reviewer").count == 3)
        let reviewerMessage = try #require(
            started.chat.items(in: "rollout-reviewer").first { $0.kind == .agentMessage }
        )
        #expect(reviewerMessage.origin == .reviewRolloutAssistant)
        #expect(reviewerMessage.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("started review classifies a unique-id live assistant after exit activity")
    func startedReviewClassifiesUniqueIDLiveAssistantAfterExitActivity() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))
        _ = started.chat.apply(.itemCompleted(
            .init(
                id: "review-exit",
                kind: .exitedReviewMode,
                content: .log("No issues found.")
            ),
            turnID: "turn-seed"
        ))
        _ = started.chat.apply(.itemCompleted(
            .init(
                id: "review-command",
                kind: .commandExecution,
                content: .command(.init(command: "/bin/zsh -lc"))
            ),
            turnID: "turn-seed"
        ))
        _ = started.chat.apply(.itemCompleted(
            .init(
                id: "msg-unique",
                kind: .agentMessage,
                content: .message(.init(
                    id: "msg-unique",
                    role: .assistant,
                    text: "No issues found."
                ))
            ),
            turnID: "turn-seed"
        ))

        let reviewerMessage = try #require(
            started.chat.items(in: "turn-seed").first { $0.itemID == "msg-unique" }
        )
        #expect(reviewerMessage.origin == .reviewRolloutAssistant)
        #expect(reviewerMessage.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("coalesced review companion waits for a full snapshot")
    func coalescedReviewCompanionWaitsForFullSnapshot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "review-chat", modelContext: context)
        let items: [CodexThreadItem] = [
            .init(
                id: "review-entry",
                kind: .enteredReviewMode,
                content: .log("current changes")
            ),
            .init(
                id: "review-exit",
                kind: .exitedReviewMode,
                content: .log("No issues found.")
            ),
            .init(
                id: "reviewer-user-1",
                kind: .userMessage,
                content: .message(.init(
                    id: "reviewer-user-1",
                    role: .user,
                    text: "current changes"
                ))
            ),
            .init(
                id: "reviewer-user-2",
                kind: .userMessage,
                content: .message(.init(
                    id: "reviewer-user-2",
                    role: .user,
                    text: "current changes"
                ))
            ),
            .init(
                id: "review-command",
                kind: .commandExecution,
                content: .command(.init(command: "/bin/zsh -lc"))
            ),
            .init(
                id: "reviewer-assistant",
                kind: .agentMessage,
                content: .message(.init(
                    id: "reviewer-assistant",
                    role: .assistant,
                    text: "No issues found."
                ))
            ),
        ]

        let summaryChanges = chat.apply(.snapshot(.init(
            id: "coalesced-review",
            state: .inProgress,
            itemsLoadState: .summary,
            items: items
        )))

        let summaryMessage = try #require(
            chat.items(in: "coalesced-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(summaryMessage.itemsLoadState == .summary)
        #expect(summaryMessage.origin == .currentV2Item)
        #expect(summaryMessage.semanticRelation == nil)
        let summaryUpdates = chat.observationUpdates(for: summaryChanges)
        #expect(summaryUpdates.contains { update in
            guard case .turnInserted(let turn, _) = update else {
                return false
            }
            return turn.items.contains {
                $0.id == "reviewer-assistant"
                    && $0.semanticRelation == nil
            }
        })

        let fullChanges = chat.apply(.snapshot(.init(
            id: "coalesced-review",
            state: .inProgress,
            itemsLoadState: .full,
            items: items
        )))

        let fullMessage = try #require(
            chat.items(in: "coalesced-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(fullMessage.itemsLoadState == .full)
        #expect(fullMessage.origin == .reviewRolloutAssistant)
        #expect(fullMessage.semanticRelation == .companionOf(.exitedReviewMode))
        let fullUpdates = chat.observationUpdates(for: fullChanges)
        #expect(fullUpdates.contains { update in
            guard case .itemUpdated(let item, let turnID, _) = update else {
                return false
            }
            return item.id == "reviewer-assistant"
                && turnID == "coalesced-review"
                && item.origin == .reviewRolloutAssistant
                && item.semanticRelation == .companionOf(.exitedReviewMode)
        })
    }

    @Test("adjacent review companion waits for a full snapshot")
    func adjacentReviewCompanionWaitsForFullSnapshot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "adjacent-review-chat", modelContext: context)
        let items: [CodexThreadItem] = [
            .init(
                id: "review-exit",
                kind: .exitedReviewMode,
                content: .log("No issues found.")
            ),
            .init(
                id: "reviewer-assistant",
                kind: .agentMessage,
                content: .message(.init(
                    id: "reviewer-assistant",
                    role: .assistant,
                    text: "No issues found."
                ))
            ),
        ]

        _ = chat.apply(.snapshot(.init(
            id: "adjacent-review",
            state: .inProgress,
            itemsLoadState: .summary,
            items: items
        )))

        let summaryMessage = try #require(
            chat.items(in: "adjacent-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(summaryMessage.itemsLoadState == .summary)
        #expect(summaryMessage.origin == .currentV2Item)
        #expect(summaryMessage.semanticRelation == nil)

        let fullChanges = chat.apply(.snapshot(.init(
            id: "adjacent-review",
            state: .inProgress,
            itemsLoadState: .full,
            items: items
        )))

        let fullMessage = try #require(
            chat.items(in: "adjacent-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(fullMessage.itemsLoadState == .full)
        #expect(fullMessage.origin == .reviewRolloutAssistant)
        #expect(fullMessage.semanticRelation == .companionOf(.exitedReviewMode))
        let fullUpdates = chat.observationUpdates(for: fullChanges)
        #expect(fullUpdates.contains { update in
            guard case .itemUpdated(let item, let turnID, _) = update else {
                return false
            }
            return item.id == "reviewer-assistant"
                && turnID == "adjacent-review"
                && item.origin == .reviewRolloutAssistant
                && item.semanticRelation == .companionOf(.exitedReviewMode)
        })
    }

    @Test("full snapshot normalization ignores stale omitted review items")
    func fullSnapshotNormalizationIgnoresStaleOmittedReviewItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "corrected-review-chat", modelContext: context)
        let assistant = CodexThreadItem(
            id: "reviewer-assistant",
            kind: .agentMessage,
            content: .message(.init(
                id: "reviewer-assistant",
                role: .assistant,
                text: "Ordinary assistant response"
            ))
        )

        _ = chat.apply(.snapshot(.init(
            id: "corrected-review",
            state: .inProgress,
            itemsLoadState: .full,
            items: [
                .init(
                    id: "review-exit",
                    kind: .exitedReviewMode,
                    content: .log("No issues found.")
                ),
                assistant,
            ]
        )))

        let classifiedMessage = try #require(
            chat.items(in: "corrected-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(classifiedMessage.origin == .reviewRolloutAssistant)
        #expect(classifiedMessage.semanticRelation == .companionOf(.exitedReviewMode))

        let correctedChanges = chat.apply(.snapshot(.init(
            id: "corrected-review",
            state: .inProgress,
            itemsLoadState: .full,
            items: [assistant]
        )))

        let correctedMessage = try #require(
            chat.items(in: "corrected-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(correctedMessage.origin == .currentV2Item)
        #expect(correctedMessage.semanticRelation == nil)
        #expect(chat.items(in: "corrected-review").contains {
            $0.itemID == "review-exit"
        } == false)
        let correctedUpdates = chat.observationUpdates(for: correctedChanges)
        #expect(correctedUpdates.contains { update in
            guard case .itemRemoved(let locator) = update else {
                return false
            }
            return locator.id == "review-exit"
                && locator.turnID == "corrected-review"
        })
        #expect(correctedUpdates.contains { update in
            guard case .itemUpdated(let item, let turnID, _) = update else {
                return false
            }
            return item.id == "reviewer-assistant"
                && turnID == "corrected-review"
                && item.origin == .currentV2Item
                && item.semanticRelation == nil
        })

        _ = chat.apply(.itemUpdated(
            .init(
                id: "reviewer-assistant",
                kind: .agentMessage,
                content: .message(.init(
                    id: "reviewer-assistant",
                    role: .assistant,
                    text: "Updated ordinary assistant response"
                ))
            ),
            turnID: "corrected-review"
        ))

        let liveUpdatedMessage = try #require(
            chat.items(in: "corrected-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(liveUpdatedMessage.origin == .currentV2Item)
        #expect(liveUpdatedMessage.semanticRelation == nil)
    }

    @Test("first snapshot classifies a persisted companion after a review exit")
    func firstSnapshotClassifiesPersistedCompanionAfterReviewExit() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "persisted-review-chat", modelContext: context)
        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "review-boundary",
                        state: .completed,
                        items: [
                            .init(
                                id: "review-exit",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        _ = chat.apply(.snapshot(.init(
            id: "persisted-companion",
            state: .completed,
            itemsLoadState: .full,
            items: [
                .init(
                    id: "reviewer-user-1",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-1",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-user-2",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-2",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "reviewer-assistant",
                        role: .assistant,
                        text: "No issues found."
                    ))
                ),
            ]
        )))

        let reviewerMessage = try #require(
            chat.items(in: "persisted-companion").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(reviewerMessage.origin == .reviewRolloutAssistant)
        #expect(reviewerMessage.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("partial snapshot uses the loaded preceding review boundary")
    func partialSnapshotUsesLoadedPrecedingReviewBoundary() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "partial-review-chat", modelContext: context)
        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "review-boundary",
                        state: .completed,
                        items: [
                            .init(
                                id: "review-exit",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "persisted-companion",
                        state: .completed,
                        items: [
                            .init(
                                id: "reviewer-user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "reviewer-user-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "reviewer-user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "reviewer-user-2",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "reviewer-assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "reviewer-assistant",
                                    role: .assistant,
                                    text: "No issues found."
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil,
            preservesExistingTurnItems: true
        )

        let reviewerMessage = try #require(
            chat.items(in: "persisted-companion").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(reviewerMessage.origin == .reviewRolloutAssistant)
        #expect(reviewerMessage.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("authoritative snapshot does not use omitted loaded review boundaries")
    func authoritativeSnapshotDoesNotUseOmittedLoadedReviewBoundaries() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "authoritative-review-chat", modelContext: context)
        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "stale-review-boundary",
                        state: .completed,
                        items: [
                            .init(
                                id: "stale-review-exit",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "ordinary-persisted-turn",
                        state: .completed,
                        items: [
                            .init(
                                id: "ordinary-user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "ordinary-user-1",
                                    role: .user,
                                    text: "repeated prompt"
                                ))
                            ),
                            .init(
                                id: "ordinary-user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "ordinary-user-2",
                                    role: .user,
                                    text: "repeated prompt"
                                ))
                            ),
                            .init(
                                id: "ordinary-assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "ordinary-assistant",
                                    role: .assistant,
                                    text: "Ordinary response"
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        let assistant = try #require(
            chat.items(in: "ordinary-persisted-turn").first {
                $0.itemID == "ordinary-assistant"
            }
        )
        #expect(assistant.origin == .currentV2Item)
        #expect(assistant.semanticRelation == nil)
        #expect(chat.turns.map(\.id) == ["ordinary-persisted-turn"])
    }

    @Test("summary record preserves its loaded full review boundary")
    func summaryRecordPreservesLoadedFullReviewBoundary() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "summarized-review-chat", modelContext: context)
        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "review-boundary",
                        state: .completed,
                        items: [
                            .init(
                                id: "review-exit",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "review-boundary",
                        state: .completed,
                        itemsLoadState: .summary
                    ),
                    .init(
                        id: "persisted-companion",
                        state: .completed,
                        items: [
                            .init(
                                id: "reviewer-user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "reviewer-user-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "reviewer-user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "reviewer-user-2",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "reviewer-assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "reviewer-assistant",
                                    role: .assistant,
                                    text: "No issues found."
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        let reviewerMessage = try #require(
            chat.items(in: "persisted-companion").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(reviewerMessage.origin == .reviewRolloutAssistant)
        #expect(reviewerMessage.semanticRelation == .companionOf(.exitedReviewMode))
        #expect(chat.items(in: "review-boundary").contains {
            $0.itemID == "review-exit"
        })
    }

    @Test("summary record cannot establish a preceding review boundary")
    func summaryRecordCannotEstablishPrecedingReviewBoundary() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "partial-review-boundary-chat", modelContext: context)

        chat.apply(
            .init(
                id: chat.id,
                turns: [
                    .init(
                        id: "partial-boundary",
                        state: .completed,
                        itemsLoadState: .summary,
                        items: [
                            .init(
                                id: "review-exit",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                    .init(
                        id: "ordinary-turn",
                        state: .completed,
                        items: [
                            .init(
                                id: "user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "user-1",
                                    role: .user,
                                    text: "repeated prompt"
                                ))
                            ),
                            .init(
                                id: "user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "user-2",
                                    role: .user,
                                    text: "repeated prompt"
                                ))
                            ),
                            .init(
                                id: "assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "assistant",
                                    role: .assistant,
                                    text: "Ordinary response"
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        let assistant = try #require(
            chat.items(in: "ordinary-turn").first { $0.itemID == "assistant" }
        )
        #expect(assistant.origin == .currentV2Item)
        #expect(assistant.semanticRelation == nil)
    }

    @Test("ordered update uses narrative evidence before the existing item")
    func orderedUpdateUsesNarrativeEvidenceBeforeExistingItem() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "ordered-review-chat", modelContext: context)

        _ = chat.apply(.itemCompleted(
            .init(
                id: "ordinary-assistant",
                kind: .agentMessage,
                content: .message(.init(
                    id: "ordinary-assistant",
                    role: .assistant,
                    text: "Ordinary response"
                ))
            ),
            turnID: "ordered-review"
        ))
        _ = chat.apply(.itemCompleted(
            .init(
                id: "later-review-exit",
                kind: .exitedReviewMode,
                content: .log("No issues found.")
            ),
            turnID: "ordered-review"
        ))
        _ = chat.apply(.itemUpdated(
            .init(
                id: "ordinary-assistant",
                kind: .agentMessage,
                content: .message(.init(
                    id: "ordinary-assistant",
                    role: .assistant,
                    text: "Updated ordinary response"
                ))
            ),
            turnID: "ordered-review"
        ))

        let assistant = try #require(
            chat.items(in: "ordered-review").first {
                $0.itemID == "ordinary-assistant"
            }
        )
        #expect(assistant.origin == .currentV2Item)
        #expect(assistant.semanticRelation == nil)
    }

    @Test("terminal transcript provides full review companion evidence")
    func terminalTranscriptProvidesFullReviewCompanionEvidence() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "terminal-review-chat", modelContext: context)
        _ = chat.apply(.turnStarted("terminal-review"))

        let terminalChanges = chat.apply(.terminal(.completed(.init(
            turnID: "terminal-review",
            transcript: .init(items: [
                .init(
                    id: "review-exit",
                    kind: .exitedReviewMode,
                    content: .log("No issues found.")
                ),
                .init(
                    id: "reviewer-user-1",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-1",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-user-2",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-2",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "reviewer-assistant",
                        role: .assistant,
                        text: "No issues found."
                    ))
                ),
            ]),
            transcriptItemsLoadState: .full
        ))))

        let turn = try #require(chat.turn(id: "terminal-review"))
        #expect(turn.itemsLoadState == .full)
        let reviewerMessage = try #require(
            chat.items(in: "terminal-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(reviewerMessage.origin == .reviewRolloutAssistant)
        #expect(reviewerMessage.semanticRelation == .companionOf(.exitedReviewMode))
        let terminalUpdates = chat.observationUpdates(for: terminalChanges)
        #expect(terminalUpdates.contains { update in
            guard case .itemInserted(let item, let turnID, _) = update else {
                return false
            }
            return item.id == "reviewer-assistant"
                && turnID == "terminal-review"
                && item.semanticRelation == .companionOf(.exitedReviewMode)
        })
    }

    @Test("summary terminal transcript does not provide full companion evidence")
    func summaryTerminalTranscriptDoesNotProvideFullCompanionEvidence() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "summary-terminal-review-chat", modelContext: context)
        _ = chat.apply(.turnStarted("summary-terminal-review"))

        _ = chat.apply(.terminal(.completed(.init(
            turnID: "summary-terminal-review",
            transcript: .init(items: [
                .init(
                    id: "review-exit",
                    kind: .exitedReviewMode,
                    content: .log("No issues found.")
                ),
                .init(
                    id: "reviewer-user-1",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-1",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-user-2",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-2",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "reviewer-assistant",
                        role: .assistant,
                        text: "No issues found."
                    ))
                ),
            ]),
            transcriptItemsLoadState: .summary
        ))))

        let turn = try #require(chat.turn(id: "summary-terminal-review"))
        #expect(turn.itemsLoadState == .summary)
        let reviewerMessage = try #require(
            chat.items(in: "summary-terminal-review").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(reviewerMessage.origin == .currentV2Item)
        #expect(reviewerMessage.semanticRelation == nil)
    }

    @Test("summary terminal transcript preserves an existing full turn")
    func summaryTerminalTranscriptPreservesExistingFullTurn() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "full-terminal-chat", modelContext: context)
        let fullItem = CodexThreadItem(
            id: "assistant",
            kind: .agentMessage,
            content: .message(.init(
                id: "assistant",
                role: .assistant,
                text: "Complete response"
            ))
        )
        _ = chat.apply(.snapshot(.init(
            id: "turn",
            state: .inProgress,
            itemsLoadState: .full,
            items: [fullItem]
        )))

        _ = chat.apply(.terminal(.completed(.init(
            turnID: "turn",
            transcript: .init(items: [
                .init(
                    id: "assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "assistant",
                        role: .assistant,
                        text: "Summary response"
                    ))
                ),
            ]),
            transcriptItemsLoadState: .summary
        ))))

        let turn = try #require(chat.turn(id: "turn"))
        #expect(turn.itemsLoadState == .full)
        let assistant = try #require(
            chat.items(in: "turn").first { $0.itemID == "assistant" }
        )
        #expect(assistant.text == "Complete response")
        #expect(assistant.itemsLoadState == .full)
    }

    @Test("full terminal transcript removes omitted live items")
    func fullTerminalTranscriptRemovesOmittedLiveItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "authoritative-terminal-chat", modelContext: context)
        _ = chat.apply(.itemCompleted(
            .init(
                id: "omitted",
                kind: .agentMessage,
                content: .message(.init(
                    id: "omitted",
                    role: .assistant,
                    text: "Omitted live item"
                ))
            ),
            turnID: "turn"
        ))
        let retainedItem = CodexThreadItem(
            id: "retained",
            kind: .agentMessage,
            content: .message(.init(
                id: "retained",
                role: .assistant,
                text: "Retained terminal item"
            ))
        )

        let changes = chat.apply(.terminal(.completed(.init(
            turnID: "turn",
            transcript: .init(items: [retainedItem]),
            transcriptItemsLoadState: .full
        ))))

        #expect(chat.items(in: "turn").map(\.itemID) == ["retained"])
        let updates = chat.observationUpdates(for: changes)
        #expect(updates.contains { update in
            guard case .itemRemoved(let locator) = update else {
                return false
            }
            return locator.id == "omitted" && locator.turnID == "turn"
        })
    }

    @Test("live persisted review companion waits for a full completion snapshot")
    func livePersistedReviewCompanionWaitsForFullCompletionSnapshot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "review-chat", modelContext: context)

        chat.apply(
            .init(
                id: chat.id,
                sourceKind: .subAgentReview,
                turns: [
                    .init(
                        id: "review-boundary",
                        state: .completed,
                        items: [
                            .init(
                                id: "review-output",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )
        _ = chat.apply(.turnStarted("reviewer-turn"))
        for id in ["reviewer-user-1", "reviewer-user-2"] {
            _ = chat.apply(.itemCompleted(
                .init(
                    id: id,
                    kind: .userMessage,
                    content: .message(.init(
                        id: id,
                        role: .user,
                        text: "current changes"
                    ))
                ),
                turnID: "reviewer-turn"
            ))
        }
        _ = chat.apply(.itemCompleted(
            .init(
                id: "reviewer-assistant",
                kind: .agentMessage,
                content: .message(.init(
                    id: "reviewer-assistant",
                    role: .assistant,
                    text: "No issues found."
                ))
            ),
            turnID: "reviewer-turn"
        ))

        let liveMessage = try #require(
            chat.items(in: "reviewer-turn").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(liveMessage.origin == .currentV2Item)
        #expect(liveMessage.semanticRelation == nil)

        _ = chat.apply(.terminal(.completed(.init(turnID: "reviewer-turn"))))

        let sparseCompletedMessage = try #require(
            chat.items(in: "reviewer-turn").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(sparseCompletedMessage.origin == .currentV2Item)
        #expect(sparseCompletedMessage.semanticRelation == nil)

        _ = chat.apply(.snapshot(.init(
            id: "reviewer-turn",
            state: .completed,
            itemsLoadState: .full,
            items: [
                .init(
                    id: "reviewer-user-1",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-1",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-user-2",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "reviewer-user-2",
                        role: .user,
                        text: "current changes"
                    ))
                ),
                .init(
                    id: "reviewer-assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "reviewer-assistant",
                        role: .assistant,
                        text: "No issues found."
                    ))
                ),
            ]
        )))

        let completedMessage = try #require(
            chat.items(in: "reviewer-turn").first {
                $0.itemID == "reviewer-assistant"
            }
        )
        #expect(completedMessage.origin == .reviewRolloutAssistant)
        #expect(completedMessage.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("persisted review companion does not depend on the thread source")
    func persistedReviewCompanionDoesNotDependOnThreadSource() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "legacy-review-chat", modelContext: context)

        chat.apply(
            .init(
                id: chat.id,
                sourceKind: .vscode,
                turns: [
                    .init(
                        id: "prior-review",
                        state: .completed,
                        items: [
                            .init(
                                id: "prior-review-output",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                    .init(
                        id: "ordinary-turn",
                        state: .completed,
                        items: [
                            .init(
                                id: "ordinary-user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "ordinary-user-1",
                                    role: .user,
                                    text: "Repeat this prompt."
                                ))
                            ),
                            .init(
                                id: "ordinary-user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "ordinary-user-2",
                                    role: .user,
                                    text: "Repeat this prompt."
                                ))
                            ),
                            .init(
                                id: "ordinary-assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "ordinary-assistant",
                                    role: .assistant,
                                    text: "This is an ordinary response."
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        let response = try #require(
            chat.items(in: "ordinary-turn").first { $0.itemID == "ordinary-assistant" }
        )
        #expect(response.origin == .reviewRolloutAssistant)
        #expect(response.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("ordinary chat does not classify a duplicate prompt without a review exit")
    func ordinaryChatDoesNotClassifyDuplicatePromptWithoutReviewExit() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "ordinary-chat", modelContext: context)

        chat.apply(
            .init(
                id: chat.id,
                sourceKind: .appServer,
                turns: [
                    .init(
                        id: "ordinary-turn",
                        state: .completed,
                        items: [
                            .init(
                                id: "ordinary-user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "ordinary-user-1",
                                    role: .user,
                                    text: "Repeat this prompt."
                                ))
                            ),
                            .init(
                                id: "ordinary-user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "ordinary-user-2",
                                    role: .user,
                                    text: "Repeat this prompt."
                                ))
                            ),
                            .init(
                                id: "ordinary-assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "ordinary-assistant",
                                    role: .assistant,
                                    text: "This is an ordinary response."
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        let response = try #require(
            chat.items(in: "ordinary-turn").first { $0.itemID == "ordinary-assistant" }
        )
        #expect(response.origin == .currentV2Item)
        #expect(response.semanticRelation == nil)
    }

    @Test("live candidate does not infer a companion from summary items")
    func liveCandidateDoesNotInferCompanionFromSummaryItems() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "summary-review-chat", modelContext: context)

        chat.apply(
            .init(
                id: chat.id,
                sourceKind: .vscode,
                turns: [
                    .init(
                        id: "review-boundary",
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "review-output",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                        ]
                    ),
                    .init(
                        id: "summary-turn",
                        state: .completed,
                        itemsLoadState: .summary,
                        items: [
                            .init(
                                id: "summary-user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "summary-user-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "summary-user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "summary-user-2",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )
        _ = chat.apply(.itemCompleted(
            .init(
                id: "summary-assistant",
                kind: .agentMessage,
                content: .message(.init(
                    id: "summary-assistant",
                    role: .assistant,
                    text: "This summary may omit narrative items."
                ))
            ),
            turnID: "summary-turn"
        ))

        let response = try #require(
            chat.items(in: "summary-turn").first {
                $0.itemID == "summary-assistant"
            }
        )
        #expect(response.origin == .currentV2Item)
        #expect(response.semanticRelation == nil)
    }

    @Test("review snapshot classifies a same-turn assistant after exit activity")
    func reviewSnapshotClassifiesSameTurnAssistantAfterExitActivity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "review-chat", modelContext: context)

        chat.apply(
            .init(
                id: chat.id,
                sourceKind: .subAgentReview,
                turns: [
                    .init(
                        id: "review-turn",
                        state: .completed,
                        items: [
                            .init(
                                id: "review-output",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                            .init(
                                id: "review-command",
                                kind: .commandExecution,
                                content: .command(.init(command: "/bin/zsh -lc"))
                            ),
                            .init(
                                id: "review-assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "review-assistant",
                                    role: .assistant,
                                    text: "No issues found."
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        let response = try #require(
            chat.items(in: "review-turn").first { $0.itemID == "review-assistant" }
        )
        #expect(response.origin == .reviewRolloutAssistant)
        #expect(response.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test("later review entry blocks a persisted companion from an earlier exit")
    func laterReviewEntryBlocksPersistedCompanionFromEarlierExit() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let chat = CodexChat(id: "review-chat", modelContext: context)

        chat.apply(
            .init(
                id: chat.id,
                sourceKind: .subAgentReview,
                turns: [
                    .init(
                        id: "review-boundaries",
                        state: .completed,
                        items: [
                            .init(
                                id: "prior-review-output",
                                kind: .exitedReviewMode,
                                content: .log("No issues found.")
                            ),
                            .init(
                                id: "later-review-entry",
                                kind: .enteredReviewMode,
                                content: .log("current changes")
                            ),
                        ]
                    ),
                    .init(
                        id: "candidate-turn",
                        state: .completed,
                        items: [
                            .init(
                                id: "candidate-user-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "candidate-user-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "candidate-user-2",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "candidate-user-2",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "candidate-assistant",
                                kind: .agentMessage,
                                content: .message(.init(
                                    id: "candidate-assistant",
                                    role: .assistant,
                                    text: "Still running."
                                ))
                            ),
                        ]
                    ),
                ]
            ),
            workspace: nil
        )

        let response = try #require(
            chat.items(in: "candidate-turn").first { $0.itemID == "candidate-assistant" }
        )
        #expect(response.origin == .currentV2Item)
        #expect(response.semanticRelation == nil)
    }

    @Test("started review coalesces multiple synthesized rollout records into the live turn")
    func startedReviewCoalescesMultipleSynthesizedRolloutRecordsIntoLiveTurn() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))

        let snapshot = CodexThreadSnapshot(
            id: "thread-review",
            workspace: workspaceURL,
            status: .active(activeFlags: []),
            turns: [
                .init(
                    id: "rollout-read-1",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "item-1",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "item-1",
                                role: .user,
                                text: "current changes"
                            ))
                        ),
                    ]
                ),
                .init(
                    id: "rollout-read-2",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "item-1",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "item-1",
                                role: .user,
                                text: "current changes updated"
                            ))
                        ),
                        .init(
                            id: "item-2",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                    ]
                ),
            ]
        )

        started.chat.apply(snapshot, workspace: started.chat.workspace)
        started.chat.apply(snapshot, workspace: started.chat.workspace)

        #expect(started.chat.turns.map(\.id) == ["turn-seed"])
        #expect(started.chat.items(in: "turn-seed").map(\.itemID) == ["item-1", "item-2"])
        #expect(started.chat.items(in: "turn-seed").map(\.text) == [
            "current changes updated", "current changes",
        ])
    }

    @Test("review mode markers preserve distinct raw identities")
    func reviewModeMarkersPreserveDistinctRawIdentities() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))
        _ = started.chat.apply(.itemStarted(
            .init(
                id: "marker-live",
                kind: .enteredReviewMode,
                content: .log("current changes")
            ),
            turnID: "turn-seed"
        ))

        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "rollout-read-1",
                        state: .inProgress,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "item-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "item-1",
                                    role: .user,
                                    text: "current changes"
                                ))
                            ),
                            .init(
                                id: "item-2",
                                kind: .enteredReviewMode,
                                content: .log("current changes")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        #expect(started.chat.turns.map(\.id) == ["turn-seed"])
        #expect(started.chat.items.filter { $0.kind == .enteredReviewMode }.count == 2)
        #expect(started.chat.items.filter { $0.kind == .userMessage }.count == 1)
    }

    @Test("started review keeps prior review turns out of the live seed")
    func startedReviewKeepsPriorReviewTurnsOutOfLiveSeed() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-seed",
            reviewThreadID: "thread-review",
            items: [
                .init(
                    id: "turn-seed",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "turn-seed",
                        role: .user,
                        text: "current changes"
                    ))
                ),
            ]
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(model: "gpt-5", ephemeral: false)
            )
        )
        _ = started.chat.apply(.turnStarted("turn-seed"))

        // A prior review's turn re-materializes with a never-seen synthesized
        // id; its exitedReviewMode item marks it as finished history that must
        // not be adopted into the live seeded turn.
        started.chat.apply(
            .init(
                id: "thread-review",
                workspace: workspaceURL,
                status: .active(activeFlags: []),
                turns: [
                    .init(
                        id: "rollout-old-review",
                        state: .completed,
                        itemsLoadState: .full,
                        items: [
                            .init(
                                id: "item-1",
                                kind: .userMessage,
                                content: .message(.init(
                                    id: "item-1",
                                    role: .user,
                                    text: "previous changes"
                                ))
                            ),
                            .init(
                                id: "item-2",
                                kind: .exitedReviewMode,
                                content: .log("Review finished")
                            ),
                        ]
                    ),
                ]
            ),
            workspace: started.chat.workspace,
            preservesExistingTurnItems: true
        )

        #expect(started.chat.turns.contains { $0.id == "rollout-old-review" })
        #expect(started.chat.turns.contains { $0.id == "turn-seed" })
        #expect(started.chat.items(in: "turn-seed").count == 1)
        #expect(started.chat.items(in: "rollout-old-review").count == 2)
    }

    @Test("started review preserves seeded row metadata across null metadata refresh")
    func startedReviewPreservesSeededRowMetadataAcrossNullMetadataRefresh() async throws {
        let workspaceURL = temporaryDirectory()
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadStart(threadID: "thread-review", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueThreadTurns(.init(profile: .currentV2, turns: [
            .init(
                id: "turn-review",
                state: .inProgress,
                itemsLoadState: .full,
                items: [
                    .init(
                        id: "review-mode",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    ),
                ]
            ),
        ]))
        try await runtime.transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-review",
                "cwd": "\(workspaceURL.path)",
                "name": null,
                "preview": null,
                "modelProvider": null
              }
            }
            """,
            for: "thread/read"
        )

        let started = try await context.startReview(
            in: workspaceURL,
            input: CodexReviewInput(
                target: .uncommittedChanges,
                options: .init(modelProvider: "openai", ephemeral: false)
            )
        )
        let expectedPreview = "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings."
        #expect(started.chat.preview == expectedPreview)
        #expect(started.chat.modelProvider == "openai")

        let observation = try await started.chat.observe()
        defer {
            observation.cancel()
        }

        #expect(started.chat.preview == expectedPreview)
        #expect(started.chat.title == expectedPreview)
        #expect(started.chat.modelProvider == "openai")
    }

    @Test("workspace start chat exposes known ephemeral option")
    func workspaceStartChatExposesKnownEphemeralOption() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let workspaceURL = temporaryDirectory()

        try await runtime.transport.enqueueUserVisibleThreadList(
            .init(profile: .currentV2, threads: [
                .init(id: "thread-existing", workspace: workspaceURL, name: "Existing")
            ]))
        let workspaceResults = context.fetchedResults(
            for: CodexFetchDescriptor<CodexWorkspace>.workspaces)
        try await workspaceResults.performFetch()
        let workspace = try #require(workspaceResults.items.first)

        try await runtime.transport.enqueueThreadStart(threadID: "thread-ephemeral")
        let chat = try await workspace.startChat(.init(options: .init(ephemeral: true)))

        #expect(chat.ephemeral == true)
    }
}

private func makeDataKitStoredThreadFixture(
    id: CodexThreadID,
    workspace: URL,
    name: String? = nil,
    preview: String? = nil,
    model: String = "gpt-5",
    modelProvider: String = "openai",
    source: CodexAppServerTestSessionSource = .cli,
    createdAt: Date = Date(timeIntervalSince1970: 10),
    updatedAt: Date = Date(timeIntervalSince1970: 20),
    ephemeral: Bool = false,
    turns: [CodexAppServerTestTurn] = [],
    isArchived: Bool = false
) throws -> CodexAppServerTestStoredThread {
    try .init(
        snapshot: .init(
            id: id,
            workspace: workspace,
            name: name,
            preview: preview ?? id.rawValue,
            modelProvider: modelProvider,
            sourceKind: source.sourceKind,
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: .idle,
            ephemeral: ephemeral,
            turns: turns.map(\.snapshot)
        ),
        turns: turns,
        metadata: .init(
            sessionID: "session-\(id.rawValue)",
            cliVersion: "codex-cli-test",
            source: source
        ),
        runtimeMetadata: .init(
            model: model,
            modelProvider: modelProvider,
            serviceTier: nil,
            cwd: workspace,
            runtimeWorkspaceRoots: [workspace],
            instructionSources: [],
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .dangerFullAccess,
            activePermissionProfile: nil,
            reasoningEffort: nil,
            multiAgentMode: .explicitRequestOnly
        ),
        isArchived: isArchived
    )
}

enum DataKitTestFixtureProfile {
    case currentV2
    case partialDTO

    var workspace: URL {
        URL(fileURLWithPath: "/tmp/codex-data-kit-current-v2", isDirectory: true)
    }

    var model: String { "gpt-5" }
    var modelProvider: String { "openai" }
    var source: CodexThreadSourceKind { .cli }
    var referenceDate: Date { Date(timeIntervalSince1970: 0) }
}

struct DataKitTestThreadFixture {
    var id: CodexThreadID
    var workspace: URL?
    var name: String?
    var preview: String?
    var modelProvider: String?
    var sourceKind: CodexThreadSourceKind?
    var createdAt: Date?
    var updatedAt: Date?
    var recencyAt: Date?
    var status: CodexThreadStatus?
    var ephemeral: Bool?
    var turns: [DataKitTestTurnFixture]?

    init(
        id: CodexThreadID,
        workspace: URL? = nil,
        name: String? = nil,
        preview: String? = nil,
        modelProvider: String? = nil,
        sourceKind: CodexThreadSourceKind? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        recencyAt: Date? = nil,
        status: CodexThreadStatus? = nil,
        ephemeral: Bool? = nil,
        turns: [DataKitTestTurnFixture]? = nil
    ) {
        self.id = id
        self.workspace = workspace
        self.name = name
        self.preview = preview
        self.modelProvider = modelProvider
        self.sourceKind = sourceKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.status = status
        self.ephemeral = ephemeral
        self.turns = turns
    }

    func withSourceKind(_ sourceKind: CodexThreadSourceKind) -> Self {
        var fixture = self
        fixture.sourceKind = sourceKind
        return fixture
    }

    func storedThread(
        profile: DataKitTestFixtureProfile,
        model: String? = nil
    ) throws -> CodexAppServerTestStoredThread {
        guard profile == .currentV2 else {
            preconditionFailure("Partial DTO fixtures do not create opaque stored threads.")
        }
        let turns = try (turns ?? []).map { try $0.turn(profile: profile) }
        let workspace = workspace ?? profile.workspace
        let modelProvider = modelProvider ?? profile.modelProvider
        let source = sourceKind ?? profile.source
        let createdAt = (createdAt ?? profile.referenceDate).wholeSecondForFixture
        let updatedAt = (updatedAt ?? createdAt).wholeSecondForFixture
        return try .init(
            snapshot: .init(
                id: id,
                workspace: workspace,
                name: name,
                preview: preview ?? name ?? id.rawValue,
                modelProvider: modelProvider,
                source: source.testSessionSource.domainProjection,
                createdAt: createdAt,
                updatedAt: updatedAt,
                recencyAt: recencyAt?.wholeSecondForFixture,
                status: status ?? .idle,
                ephemeral: ephemeral ?? false,
                turns: turns.map(\.snapshot)
            ),
            turns: turns,
            metadata: .init(
                sessionID: "data-kit-session-\(id.rawValue)",
                parentThreadID: source == .subAgentThreadSpawn
                    ? "data-kit-testing-parent"
                    : nil,
                cliVersion: "codex-data-kit-tests",
                source: source.testSessionSource
            ),
            runtimeMetadata: .init(
                model: model ?? profile.model,
                modelProvider: modelProvider,
                serviceTier: nil,
                cwd: workspace,
                runtimeWorkspaceRoots: [workspace],
                instructionSources: [],
                approvalPolicy: .never,
                approvalsReviewer: .user,
                sandbox: .dangerFullAccess,
                activePermissionProfile: nil,
                reasoningEffort: nil,
                multiAgentMode: .explicitRequestOnly
            ),
            isArchived: false
        )
    }
}

struct DataKitTestTurnFixture {
    var id: CodexTurnID
    var state: CodexTurnSnapshot.State
    var itemsLoadState: CodexTurnItemsLoadState
    var items: [CodexThreadItem]
    var startedAt: Date?
    var completedAt: Date?
    var duration: Duration?

    init(
        id: CodexTurnID,
        state: CodexTurnSnapshot.State,
        itemsLoadState: CodexTurnItemsLoadState = .full,
        items: [CodexThreadItem] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        duration: Duration? = nil
    ) {
        self.id = id
        self.state = state
        self.itemsLoadState = itemsLoadState
        self.items = items
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
    }

    func turn(
        profile: DataKitTestFixtureProfile
    ) throws -> CodexAppServerTestTurn {
        let items = try items.map { try $0.testItem(profile: profile) }
        return try .init(
            snapshot: .init(
                id: id,
                state: state,
                itemsLoadState: itemsLoadState,
                items: items.map(\.domainProjection),
                startedAt: startedAt,
                completedAt: completedAt,
                duration: duration
            ),
            items: items
        )
    }

    func dto(
        profile: DataKitTestFixtureProfile
    ) throws -> AppServerAPI.Turn.Payload {
        let turn = try turn(profile: profile)
        return try JSONDecoder().decode(
            AppServerAPI.Turn.Payload.self,
            from: JSONEncoder().encode(turn.wireValue)
        )
    }
}

struct DataKitTestThreadPage {
    enum Payload {
        case opaque(CodexAppServerTestThreadPage)
        case dto(AppServerAPI.Thread.List.Response)
    }

    var payload: Payload

    init(
        profile: DataKitTestFixtureProfile,
        threads: [DataKitTestThreadFixture],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) throws {
        switch profile {
        case .currentV2:
            self.payload = try .opaque(.init(
                threads: threads.map { try $0.storedThread(profile: profile) },
                nextCursor: nextCursor,
                backwardsCursor: backwardsCursor
            ))
        case .partialDTO:
            self.payload = try .dto(.init(
                data: threads.map { try $0.dto(profile: profile) },
                nextCursor: nextCursor,
                backwardsCursor: backwardsCursor
            ))
        }
    }
}

struct DataKitTestTurnPage {
    var page: CodexAppServerTestTurnPage

    init(
        profile: DataKitTestFixtureProfile,
        turns: [DataKitTestTurnFixture],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) throws {
        self.page = try .init(
            turns: turns.map { try $0.turn(profile: profile) },
            nextCursor: nextCursor,
            backwardsCursor: backwardsCursor
        )
    }
}

extension CodexAppServerTestTransport {
    func enqueueUserVisibleThreadListJSON(_ interactiveResponse: String) throws {
        try enqueueJSON(interactiveResponse, for: "thread/list")
        try enqueueThreadList(.init(threads: []))
    }

    func enqueueUserVisibleThreadList(_ page: CodexAppServerTestThreadPage) throws {
        try enqueueThreadList(page)
        guard page.nextCursor == nil else {
            return
        }
        try enqueueThreadList(.init(threads: []))
    }

    func enqueueUserVisibleThreadList(_ page: DataKitTestThreadPage) throws {
        switch page.payload {
        case .opaque(let page):
            try enqueueUserVisibleThreadList(page)
        case .dto(let response):
            try enqueue(response, for: "thread/list")
            guard response.nextCursor == nil else {
                return
            }
            try enqueue(
                AppServerAPI.Thread.List.Response(
                    data: [],
                    nextCursor: nil,
                    backwardsCursor: nil
                ),
                for: "thread/list"
            )
        }
    }

    func enqueueBoundedUserVisibleThreadList(_ page: CodexAppServerTestThreadPage) throws {
        try enqueueThreadList(page)
        try enqueueThreadList(.init(threads: []))
    }

    func enqueueBoundedUserVisibleThreadList(_ page: DataKitTestThreadPage) throws {
        switch page.payload {
        case .opaque(let page):
            try enqueueBoundedUserVisibleThreadList(page)
        case .dto(let response):
            try enqueue(response, for: "thread/list")
            try enqueue(
                AppServerAPI.Thread.List.Response(
                    data: [],
                    nextCursor: nil,
                    backwardsCursor: nil
                ),
                for: "thread/list"
            )
        }
    }

    func enqueueThreadList(_ page: DataKitTestThreadPage) throws {
        switch page.payload {
        case .opaque(let page):
            try enqueueThreadList(page)
        case .dto(let response):
            try enqueue(response, for: "thread/list")
        }
    }

    func enqueueThreadTurns(_ page: DataKitTestTurnPage) throws {
        try enqueueThreadTurns(page.page)
    }

    func enqueueThreadStart(threadID: String, model: String? = nil) throws {
        try enqueueThreadStart(
            DataKitTestThreadFixture(id: .init(rawValue: threadID))
                .storedThread(profile: .currentV2, model: model)
        )
    }

    func enqueueThreadResume(
        _ thread: DataKitTestThreadFixture,
        model: String? = nil
    ) throws {
        try enqueueThreadResume(
            thread.storedThread(profile: .currentV2, model: model)
        )
    }

    func enqueueThreadRead(_ thread: DataKitTestThreadFixture) throws {
        try enqueueThreadRead(thread.storedThread(profile: .currentV2))
    }

    func enqueueThreadUnarchive(_ thread: DataKitTestThreadFixture) throws {
        try enqueueThreadUnarchive(thread.storedThread(profile: .currentV2))
    }

    func enqueueTurnStart(
        turnID: String,
        status: String = "inProgress"
    ) throws {
        try enqueueTurnStart(try DataKitTestTurnFixture(
            id: .init(rawValue: turnID),
            state: status.testTurnState
        ).turn(profile: .currentV2))
    }

    func enqueueReviewStart(
        turnID: String,
        reviewThreadID: String,
        status: CodexTurnStatus = .inProgress,
        items: [CodexThreadItem] = []
    ) throws {
        try enqueueReviewStart(
            try DataKitTestTurnFixture(
                id: .init(rawValue: turnID),
                state: status.testTurnState,
                items: items
            ).turn(profile: .currentV2),
            reviewThreadID: .init(rawValue: reviewThreadID)
        )
    }

    func enqueueReviewStart(
        _ turn: DataKitTestTurnFixture,
        reviewThreadID: String
    ) throws {
        try enqueueReviewStart(
            try turn.turn(profile: .currentV2),
            reviewThreadID: .init(rawValue: reviewThreadID)
        )
    }
}

private extension DataKitTestThreadFixture {
    func dto(
        profile: DataKitTestFixtureProfile
    ) throws -> AppServerAPI.Thread.Snapshot {
        .init(
            id: id.rawValue,
            cwd: workspace?.path,
            name: name,
            preview: preview,
            modelProvider: modelProvider,
            source: sourceKind.map { $0.testSessionSource.appServerValue },
            createdAt: createdAt.map { Int($0.timeIntervalSince1970) },
            updatedAt: updatedAt.map { Int($0.timeIntervalSince1970) },
            recencyAt: recencyAt.map { Int($0.timeIntervalSince1970) },
            status: status.map { status in
                switch status {
                case .active(let activeFlags):
                    .init(type: status.rawValue, activeFlags: activeFlags.map(\.rawValue))
                case .notLoaded, .idle, .systemError, .unknown:
                    .init(type: status.rawValue)
                }
            },
            ephemeral: ephemeral,
            turns: try turns?.map { try $0.dto(profile: profile) }
        )
    }
}

private extension CodexThreadItem {
    func testItem(
        profile: DataKitTestFixtureProfile
    ) throws -> CodexAppServerTestItem {
        switch (kind, content) {
        case (.userMessage, .message(let message)):
            return try .userMessage(id: id, text: message.text)
        case (.agentMessage, .message(let message)):
            return try .agentMessage(id: id, text: message.text, phase: message.phase)
        case (.enteredReviewMode, .log(let review)):
            return try .enteredReviewMode(id: id, review: review)
        case (.exitedReviewMode, .log(let review)):
            return try .exitedReviewMode(id: id, review: review)
        case (.reasoning, .reasoning(let reasoning)):
            return try .reasoning(id: id, summary: reasoning.summary, content: reasoning.content)
        case (.commandExecution, .command(let command)):
            return try .commandExecution(
                id: id,
                command: command.command,
                cwd: URL(
                    fileURLWithPath: command.cwd ?? profile.workspace.path,
                    isDirectory: true
                ),
                processID: command.processID,
                source: .agent,
                status: command.status.testCommandStatus,
                aggregatedOutput: command.output,
                exitCode: command.exitCode.flatMap(Int32.init(exactly:)),
                duration: command.duration
            )
        case (.mcpToolCall, .toolCall(let call)):
            guard let server = call.server, let tool = call.name else {
                throw CodexAppServerTestError.invalidFixture(
                    "DataKit current-v2 MCP fixtures require server and tool names."
                )
            }
            return try .mcpToolCall(
                id: id,
                server: server,
                tool: tool,
                status: call.status.testMCPStatus,
                resultContent: call.result.map { [.string($0)] },
                errorMessage: call.error
            )
        default:
            throw CodexAppServerTestError.invalidFixture(
                "Unsupported DataKit current-v2 item fixture \(kind.rawValue)."
            )
        }
    }
}

private extension Optional where Wrapped == CodexTurnStatus {
    var testCommandStatus: CodexAppServerTestItem.CommandStatus {
        switch self {
        case .some(.completed): .completed
        case .some(.failed), .some(.interrupted): .failed
        case .some(.inProgress), .some(.unknown), .none: .inProgress
        }
    }

    var testMCPStatus: CodexAppServerTestItem.MCPStatus {
        switch self {
        case .some(.completed): .completed
        case .some(.failed), .some(.interrupted): .failed
        case .some(.inProgress), .some(.unknown), .none: .inProgress
        }
    }
}

private extension Date {
    var wholeSecondForFixture: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.towardZero))
    }
}

private extension String {
    var testTurnState: CodexTurnSnapshot.State {
        switch self {
        case "inProgress", "running":
            .inProgress
        case "completed":
            .completed
        case "interrupted":
            .interrupted
        default:
            .unknown(rawValue: self, error: nil)
        }
    }
}

private extension CodexTurnStatus {
    var testTurnState: CodexTurnSnapshot.State {
        switch self {
        case .inProgress:
            .inProgress
        case .completed:
            .completed
        case .interrupted:
            .interrupted
        case .failed:
            .failed(.init(message: "Testing review failure"))
        case .unknown(let rawValue):
            .unknown(rawValue: rawValue, error: nil)
        }
    }
}

private extension CodexThreadSourceKind {
    var testSessionSource: CodexAppServerTestSessionSource {
        switch self {
        case .cli:
            .cli
        case .vscode:
            .vscode
        case .exec:
            .exec
        case .appServer:
            .appServer
        case .subAgentReview:
            .subAgentReview
        case .subAgentCompact:
            .subAgentCompact
        case .subAgentThreadSpawn:
            .subAgentThreadSpawn(
                parentThreadID: "data-kit-testing-parent",
                depth: 0,
                agentPath: nil,
                agentNickname: nil,
                agentRole: nil
            )
        case .subAgentOther:
            .subAgentOther("data-kit-testing")
        case .subAgent:
            .subAgentMemoryConsolidation
        case .unknown:
            .unknown
        default:
            .custom(rawValue)
        }
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func createDirectory(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func gitRepository() throws -> URL {
    let repo = temporaryDirectory()
    try createGitMetadata(in: repo)
    return repo
}

private func gitRepository(named name: String) throws -> URL {
    let repo = temporaryDirectory().appendingPathComponent(name, isDirectory: true)
    try createGitMetadata(in: repo)
    return repo
}

private func createGitMetadata(in repo: URL) throws {
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
}

private struct ThreadListParams: Decodable, Sendable {
    var archived: Bool?
    var cursor: String?
    var cwd: CWDFilter?
    var limit: Int?
    var modelProviders: [String]?
    var searchTerm: String?
    var sortDirection: String?
    var sortKey: String?
    var sourceKinds: [String]?
    var useStateDbOnly: Bool?
}

private enum CWDFilter: Decodable, Equatable, Sendable {
    case path(String)
    case paths([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let path = try? container.decode(String.self) {
            self = .path(path)
        } else {
            self = .paths(try container.decode([String].self))
        }
    }
}

private struct ThreadReadParams: Decodable, Sendable {
    var threadID: String
    var includeTurns: Bool?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case includeTurns
    }
}

private struct ThreadTurnsListParams: Decodable, Sendable {
    var threadID: String
    var cursor: String?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case cursor
    }
}

private struct ThreadStartParams: Decodable, Sendable {
    var cwd: String?
    var model: String?
    var modelProvider: String?
    var ephemeral: Bool?
}

private struct ThreadItemParams: Encodable, Sendable {
    enum Lifecycle: Sendable {
        case started
        case completed
    }

    var lifecycle: Lifecycle
    var threadID: String
    var turnID: String
    var startedAtMs: Int64? = nil
    var completedAtMs: Int64? = nil
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case startedAtMs
        case completedAtMs
        case item
    }

    init(
        lifecycle: Lifecycle,
        threadID: String,
        turnID: String,
        startedAtMs: Int64? = nil,
        completedAtMs: Int64? = nil,
        item: Item
    ) {
        self.lifecycle = lifecycle
        self.threadID = threadID
        self.turnID = turnID
        self.startedAtMs = startedAtMs
        self.completedAtMs = completedAtMs
        self.item = item
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(turnID, forKey: .turnID)
        switch lifecycle {
        case .started:
            try container.encode(startedAtMs ?? 0, forKey: .startedAtMs)
        case .completed:
            try container.encode(completedAtMs ?? 0, forKey: .completedAtMs)
        }
        var item = item
        switch item.type {
        case "commandExecution":
            item.command = item.command ?? item.text ?? ""
            item.cwd = item.cwd ?? "/workspace"
            item.commandActions = []
            item.aggregatedOutput = item.output ?? item.text
            item.status = lifecycle == .started ? "inProgress" : "completed"
        case "fileChange":
            item.status = lifecycle == .started ? "inProgress" : "completed"
            item.changes = [
                .init(
                    diff: item.text ?? item.output ?? "",
                    kind: .init(type: "update"),
                    path: item.path ?? "/workspace/File.swift"
                )
            ]
        case "enteredReviewMode", "exitedReviewMode":
            item.review = item.text ?? ""
        default:
            break
        }
        try container.encode(item, forKey: .item)
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String? = nil
        var phase: String? = nil
        var command: String? = nil
        var cwd: String? = nil
        var path: String? = nil
        var output: String? = nil
        var exitCode: Int? = nil
        var status: String? = nil
        var durationMs: Int? = nil
        var aggregatedOutput: String? = nil
        var commandActions: [String]? = nil
        var review: String? = nil
        var changes: [FileChange]? = nil

        struct FileChange: Encodable, Sendable {
            var diff: String
            var kind: Kind
            var path: String

            struct Kind: Encodable, Sendable {
                var type: String
            }
        }
    }
}

private struct TurnStartedParams: Encodable, Sendable {
    var threadID: String
    var turn: Turn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turn = .init(id: turnID)
    }

    struct Turn: Encodable, Sendable {
        var id: String
        var status = "inProgress"
        var items: [String] = []
    }
}

private struct TurnDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String
    var phase: String?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case phase
    }
}

private struct OutputDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

private struct FileChangePatchUpdatedParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var changes: [Change]

    init(threadID: String, turnID: String, itemID: String, displayText: String) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.changes = [
            .init(
                diff: displayText,
                kind: .init(type: "update"),
                path: "Sources/File.swift"
            )
        ]
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case changes
    }

    struct Change: Encodable, Sendable {
        var diff: String
        var kind: Kind
        var path: String

        struct Kind: Encodable, Sendable {
            var type: String
        }
    }
}

private struct ThreadStatusParams: Encodable, Sendable {
    var threadID: String
    var status: Status

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }

    struct Status: Encodable, Sendable {
        var type: String
        var activeFlags: [String] = []
    }
}

private struct ThreadClosedParams: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var threadID: String
    var turn: Turn

    init(threadID: String, turn: Turn) {
        self.threadID = threadID
        self.turn = turn
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    struct Turn: Encodable, Sendable {
        var id: String
        var status: String
        var items: [String]
        var completedAt: Int?
        var error: Error?

        init(
            id: String,
            status: String,
            completedAt: Int? = nil,
            error: Error? = nil,
            items: [String] = []
        ) {
            self.id = id
            self.status = status
            self.completedAt = completedAt
            self.error = error
            self.items = items
        }
    }

    struct Error: Encodable, Sendable {
        var message: String
        var codexErrorInfo: String?
        var additionalDetails: String?

        init(
            message: String,
            codexErrorInfo: String? = nil,
            additionalDetails: String? = nil
        ) {
            self.message = message
            self.codexErrorInfo = codexErrorInfo
            self.additionalDetails = additionalDetails
        }
    }
}

private struct TokenUsageParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var tokenUsage: TokenUsage

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case tokenUsage
    }

    struct TokenUsage: Encodable, Sendable {
        var last: Breakdown
        var total: Breakdown
        var modelContextWindow: Int?

        init(total: Breakdown, modelContextWindow: Int? = nil) {
            self.last = total
            self.total = total
            self.modelContextWindow = modelContextWindow
        }
    }

    struct Breakdown: Encodable, Sendable {
        var cachedInputTokens: Int = 0
        var inputTokens: Int
        var outputTokens: Int
        var reasoningOutputTokens: Int = 0
        var totalTokens: Int
    }
}

private func emitAgentMessageStarted(
    on transport: CodexAppServerTestTransport,
    threadID: String,
    turnID: String,
    itemID: String,
    text: String = "",
    phase: String? = nil
) async throws {
    try await transport.emitServerNotification(
        method: "item/started",
        params: ThreadItemParams(
            lifecycle: .started,
            threadID: threadID,
            turnID: turnID,
            item: .init(
                id: itemID,
                type: "agentMessage",
                text: text,
                phase: phase
            )
        )
    )
}

@MainActor
private func eventually(
    attempts: Int = 50,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private func threadItems(from items: [CodexItem]) -> [CodexThreadItem] {
    items.map {
        CodexThreadItem(
            id: $0.itemID,
            kind: $0.kind,
            content: $0.content,
            rawPayload: $0.rawPayload
        )
    }
}

@MainActor
private final class FetchedResultsTransactionRecorder<Model: CodexPersistentModel> {
    private(set) var transactions: [CodexFetchedResultsTransaction<Model>] = []
    private var task: Task<Void, Never>?

    init(stream: AsyncStream<CodexFetchedResultsTransaction<Model>>) {
        task = Task { @MainActor [weak self] in
            for await transaction in stream {
                self?.transactions.append(transaction)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    func count(after delay: Duration) async -> Int {
        try? await Task.sleep(for: delay)
        return transactions.count
    }
}

@MainActor
private final class ChatUpdateRecorder {
    private var changes: [CodexChatUpdate] = []
    private var snapshots: [(CodexChatObservationSnapshot, CodexChatSnapshotReason)] = []
    private var streamFinished = false
    private var task: Task<Void, Never>?

    init(stream: CodexChatUpdates) {
        task = Task { @MainActor [weak self] in
            for await event in stream {
                self?.append(event)
            }
            self?.markFinished()
        }
    }

    deinit {
        task?.cancel()
    }

    func next() async -> CodexChatUpdate? {
        await next { _ in true }
    }

    func itemInserted(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemInserted(let item, _, _) = change {
                return item.id == id
            }
            if case .turnInserted(let turn, _) = change {
                return turn.items.contains { $0.id == id }
            }
            return false
        }
    }

    func itemUpdated(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemUpdated(let item, _, _) = change {
                return item.id == id
            }
            if case .turnUpdated(let turn, _) = change {
                return turn.items.contains { $0.id == id }
            }
            return false
        }
    }

    func itemRemoved(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemRemoved(let locator) = change {
                return locator.id == id
            }
            return false
        }
    }

    func itemTextAppended(id: String, delta: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemTextAppended(let locator, let changeDelta) = change {
                return locator.id == id && changeDelta == delta
            }
            return false
        }
    }

    func phaseChanged(_ phase: CodexChatPhase) async -> CodexChatUpdate? {
        await next { change in
            if case .phaseChanged(let candidate) = change {
                return candidate == phase
            }
            return false
        }
    }

    func statusChanged(_ status: CodexThreadStatus?) async -> CodexChatUpdate? {
        await next { change in
            if case .statusChanged(let candidate) = change {
                return candidate == status
            }
            return false
        }
    }

    func snapshot(reason: CodexChatSnapshotReason) async -> CodexChatObservationSnapshot? {
        for _ in 0..<50 {
            if let index = snapshots.firstIndex(where: { $0.1 == reason }) {
                return snapshots.remove(at: index).0
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    var isFinished: Bool {
        streamFinished
    }

    private func append(_ event: CodexChatObservationEvent) {
        switch event.payload {
        case .update(let change):
            changes.append(change)
        case .snapshot(let snapshot, let reason):
            snapshots.append((snapshot, reason))
        }
    }

    private func markFinished() {
        streamFinished = true
    }

    private func popFirst(
        matching predicate: (CodexChatUpdate) -> Bool
    ) -> CodexChatUpdate? {
        guard let index = changes.firstIndex(where: predicate) else {
            return nil
        }
        return changes.remove(at: index)
    }

    private func next(
        matching predicate: (CodexChatUpdate) -> Bool
    ) async -> CodexChatUpdate? {
        for _ in 0..<50 {
            if let change = popFirst(matching: predicate) {
                return change
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return popFirst(matching: predicate)
    }
}
