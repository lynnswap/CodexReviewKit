import Foundation
import Testing

@testable import CodexAppServerKit
@testable import CodexAppServerKitTesting

@Suite("CodexAppServerTestStoredThread")
struct CodexAppServerTestStoredThreadTests {
    @Test func userMessageOwnsCanonicalCurrentV2Content() throws {
        let item = try CodexAppServerTestItem.userMessage(
            id: "user-message-1",
            text: "Review this change"
        )

        #expect(item.domainProjection.kind == .userMessage)
        #expect(item.domainProjection.text == "Review this change")
        #expect(item.wireValue == .object([
            "id": .string("user-message-1"),
            "type": .string("userMessage"),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Review this change"),
                    "textElements": .array([]),
                ])
            ]),
        ]))
    }

    @Test func canonicalWireValuesComeOnlyFromValidatedOpaqueFixtures() throws {
        let fixture = try makeStoredThreadFixture(historyMode: .paginated)

        guard case .object(let thread) = fixture.stored.wireValue else {
            Issue.record("Expected a canonical stored-thread wire object.")
            return
        }
        #expect(thread["id"] == .string("thread-1"))
        #expect(thread["sessionId"] == .string("session-1"))
        #expect(thread["forkedFromId"] == .null)
        #expect(thread["parentThreadId"] == .null)
        #expect(thread["historyMode"] == .string("paginated"))
        #expect(thread["source"] == .string("appServer"))
        #expect(thread["cwd"] == .string(fixture.workspace.path))
        #expect(thread["turns"] == .array([fixture.turn.wireValue]))
        #expect(thread["path"] == .null)
        #expect(thread["threadSource"] == .null)

        guard case .object(let runtime) = fixture.runtimeMetadata.wireValue else {
            Issue.record("Expected canonical runtime metadata wire fields.")
            return
        }
        #expect(runtime["model"] == .string("gpt-5-codex"))
        #expect(runtime["modelProvider"] == .string("openai"))
        #expect(runtime["cwd"] == .string(fixture.workspace.path))
        #expect(
            runtime["runtimeWorkspaceRoots"]
                == .array([
                    .string(fixture.workspace.path)
                ]))
        #expect(
            runtime["instructionSources"]
                == .array([
                    .string(fixture.instructions.path)
                ]))
        #expect(
            runtime["approvalPolicy"]
                == .object([
                    "granular": .object([
                        "sandbox_approval": .bool(true),
                        "rules": .bool(false),
                        "skill_approval": .bool(true),
                        "request_permissions": .bool(false),
                        "mcp_elicitations": .bool(true),
                    ])
                ]))
        #expect(runtime["approvalsReviewer"] == .string("auto_review"))
        #expect(
            runtime["activePermissionProfile"]
                == .object([
                    "id": .string("workspace"),
                    "extends": .string("base"),
                ]))
        #expect(runtime["reasoningEffort"] == .string("high"))
        #expect(
            runtime["multiAgentMode"]
                == .object([
                    "custom": .string("delegate focused work")
                ]))

        let threadPage = CodexAppServerTestThreadPage(
            threads: [fixture.stored],
            nextCursor: "thread-next"
        )
        guard case .object(let threadPageWire) = threadPage.wireValue,
            case .array(let listedValues)? = threadPageWire["data"],
            listedValues.count == 1,
            case .object(let listedThread) = listedValues[0]
        else {
            Issue.record("Expected one canonical listed thread.")
            return
        }
        #expect(listedThread["turns"] == .array([]))
        #expect(threadPageWire["nextCursor"] == .string("thread-next"))
        #expect(threadPageWire["backwardsCursor"] == .null)

        let turnPage = CodexAppServerTestTurnPage(
            turns: [fixture.turn],
            backwardsCursor: "turn-previous"
        )
        #expect(
            turnPage.wireValue
                == .object([
                    "data": .array([fixture.turn.wireValue]),
                    "nextCursor": .null,
                    "backwardsCursor": .string("turn-previous"),
                ]))
    }

    @Test func canonicalSessionSourceProjectsSubAgentReview() throws {
        let stored = try makeRuntimeStoredThreadFixture(
            id: "thread-review",
            source: .subAgentReview
        )

        guard case .object(let wire) = stored.wireValue else {
            Issue.record("Expected a canonical stored-thread wire object.")
            return
        }
        #expect(wire["source"] == .object(["subAgent": .string("review")]))
        #expect(stored.snapshot.sourceKind == .subAgentReview)
    }

    @Test func threadStoreListUsesProductionSourceFilterSemantics() async throws {
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            makeRuntimeStoredThreadFixture(id: "cli", source: .cli),
            makeRuntimeStoredThreadFixture(id: "vscode", source: .vscode),
            makeRuntimeStoredThreadFixture(id: "atlas", source: .custom("atlas")),
            makeRuntimeStoredThreadFixture(id: "chatgpt", source: .custom("chatgpt")),
            makeRuntimeStoredThreadFixture(id: "custom", source: .custom("other")),
            makeRuntimeStoredThreadFixture(id: "exec", source: .exec),
            makeRuntimeStoredThreadFixture(id: "app-server", source: .appServer),
            makeRuntimeStoredThreadFixture(id: "review", source: .subAgentReview),
            makeRuntimeStoredThreadFixture(id: "compact", source: .subAgentCompact),
        ])

        let interactiveIDs = ["cli", "vscode", "atlas", "chatgpt"]
        #expect(try await runtime.server.listThreads().threads.map(\.id.rawValue) == interactiveIDs)
        #expect(try await runtime.server.listThreads(.init(
            sourceKinds: []
        )).threads.map(\.id.rawValue) == interactiveIDs)
        #expect(try await runtime.server.listThreads(.init(
            sourceKinds: [.appServer]
        )).threads.map(\.id.rawValue) == ["app-server"])
        #expect(try await runtime.server.listThreads(.init(
            sourceKinds: [.subAgentReview]
        )).threads.map(\.id.rawValue) == ["review"])
        #expect(try await runtime.server.listThreads(.init(
            sourceKinds: [.subAgent]
        )).threads.map(\.id.rawValue) == ["review", "compact"])

        await runtime.close()
    }

    @Test func threadStoreRecencySortUsesThreadIDTieBreakerAcrossPages() async throws {
        let recencyAt = Date(timeIntervalSince1970: 100)
        let firstID = CodexThreadID("00000000-0000-0000-0000-000000000001")
        let secondID = CodexThreadID("00000000-0000-0000-0000-000000000002")
        let thirdID = CodexThreadID("00000000-0000-0000-0000-000000000003")
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            makeRuntimeStoredThreadFixture(id: secondID, recencyAt: recencyAt),
            makeRuntimeStoredThreadFixture(id: firstID, recencyAt: recencyAt),
            makeRuntimeStoredThreadFixture(id: thirdID, recencyAt: recencyAt),
        ])

        for (direction, expectedIDs) in [
            (CodexSortDirection.ascending, [firstID, secondID, thirdID]),
            (CodexSortDirection.descending, [thirdID, secondID, firstID]),
        ] {
            let firstPage = try await runtime.server.listThreads(.init(
                limit: 2,
                sortDirection: direction,
                sortKey: .recencyAt
            ))
            #expect(firstPage.threads.map(\.id) == Array(expectedIDs.prefix(2)))
            let nextCursor = try #require(firstPage.nextCursor)

            let secondPage = try await runtime.server.listThreads(.init(
                cursor: nextCursor,
                limit: 2,
                sortDirection: direction,
                sortKey: .recencyAt
            ))
            #expect(secondPage.threads.map(\.id) == Array(expectedIDs.dropFirst(2)))
            #expect(secondPage.nextCursor == nil)
            #expect(secondPage.backwardsCursor != nil)
        }

        await runtime.close()
    }

    @Test func threadStoreListClampsProductionPageSize() async throws {
        let runtime = try await CodexAppServerTestRuntime.start(threads: (0..<102).map { index in
            try makeRuntimeStoredThreadFixture(id: CodexThreadID(rawValue: "thread-\(index)"))
        })

        let defaultPage = try await runtime.server.listThreads()
        #expect(defaultPage.threads.count == 25)
        #expect(defaultPage.nextCursor != nil)

        let minimumPage = try await runtime.server.listThreads(.init(limit: 0))
        #expect(minimumPage.threads.count == 1)
        #expect(minimumPage.nextCursor != nil)

        let maximumPage = try await runtime.server.listThreads(.init(limit: 101))
        #expect(maximumPage.threads.count == 100)
        let maximumNextCursor = try #require(maximumPage.nextCursor)

        let maximumSecondPage = try await runtime.server.listThreads(.init(
            cursor: maximumNextCursor,
            limit: 101
        ))
        #expect(maximumSecondPage.threads.count == 2)
        #expect(maximumSecondPage.nextCursor == nil)

        await runtime.close()
    }

    @Test func replacingTurnsRevalidatesProjectionAndPreservesHiddenMetadata() throws {
        let fixture = try makeStoredThreadFixture()
        let replacementItem = try CodexAppServerTestItem.plan(
            id: "plan-2",
            text: "Updated plan"
        )
        let replacementTurn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-2",
                state: .completed,
                itemsLoadState: .summary,
                items: [replacementItem.domainProjection]
            ),
            items: [replacementItem]
        )

        let replacement = try fixture.stored.replacingTurns([replacementTurn])

        #expect(fixture.stored.turns == [fixture.turn])
        #expect(replacement.turns == [replacementTurn])
        #expect(replacement.snapshot.turns == [replacementTurn.snapshot])
        #expect(replacement.snapshot.turnItemsAreAuthoritative == false)
        #expect(replacement.metadata == fixture.stored.metadata)
        #expect(replacement.runtimeMetadata == fixture.stored.runtimeMetadata)
        #expect(replacement.isArchived == fixture.stored.isArchived)
        guard case .object(let wire) = replacement.wireValue else {
            Issue.record("Expected a replacement stored-thread wire object.")
            return
        }
        #expect(wire["turns"] == .array([replacementTurn.wireValue]))
    }

    @Test func runtimeMetadataRejectsInvalidRequiredValuesAndFilesystemURLs() throws {
        let workspace = URL(fileURLWithPath: "/tmp/codex-kit-fixture", isDirectory: true)
        let webURL = try #require(URL(string: "https://example.com/workspace"))
        let relativeFileURL = try #require(URL(string: "file:relative"))

        #expect(throws: CodexAppServerTestError.invalidFixture("model must not be empty")) {
            _ = try makeRuntimeMetadata(model: " ", cwd: workspace)
        }
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "model provider must not be empty"
            )
        ) {
            _ = try makeRuntimeMetadata(modelProvider: "\n", cwd: workspace)
        }
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "cwd must be an absolute file URL"
            )
        ) {
            _ = try makeRuntimeMetadata(cwd: webURL)
        }
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "runtime workspace root must be an absolute file URL"
            )
        ) {
            _ = try makeRuntimeMetadata(
                cwd: workspace,
                runtimeWorkspaceRoots: [relativeFileURL]
            )
        }
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "instruction source must be an absolute file URL"
            )
        ) {
            _ = try makeRuntimeMetadata(cwd: workspace, instructionSources: [webURL])
        }
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "sandbox writable root must be an absolute file URL"
            )
        ) {
            _ = try makeRuntimeMetadata(
                cwd: workspace,
                sandbox: .workspaceWrite(
                    writableRoots: [webURL],
                    networkAccess: false,
                    excludeTmpdirEnvVar: false,
                    excludeSlashTmp: false
                )
            )
        }
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "custom multi-agent mode must not be empty"
            )
        ) {
            _ = try makeRuntimeMetadata(cwd: workspace, multiAgentMode: .custom(" "))
        }
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "active permission profile id must not be empty"
            )
        ) {
            _ = try CodexAppServerTestThreadRuntimeMetadata.ActivePermissionProfile(id: " ")
        }
    }

    @Test func storedThreadRejectsMissingAndInconsistentProjections() throws {
        let fixture = try makeStoredThreadFixture()

        var missingPreview = fixture.snapshot
        missingPreview.preview = nil
        #expect(throws: CodexAppServerTestError.invalidFixture("thread preview is required")) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: missingPreview,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var mismatchedTurns = fixture.snapshot
        mismatchedTurns.turns = []
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread snapshot turns must match the Testing turn projections"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: mismatchedTurns,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var mismatchedSource = fixture.snapshot
        mismatchedSource.sourceKind = .cli
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread snapshot source must match the Testing thread metadata"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: mismatchedSource,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var explicitNullSession = fixture.snapshot
        explicitNullSession.sessionID = nil
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread snapshot session id must match the Testing thread metadata"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: explicitNullSession,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var explicitNullSource = fixture.snapshot
        explicitNullSource.source = nil
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread snapshot source must match the Testing thread metadata"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: explicitNullSource,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var spawnMetadata = fixture.metadata
        spawnMetadata.source = .subAgentThreadSpawn(
            parentThreadID: "source-parent",
            depth: 1,
            agentPath: nil,
            agentNickname: nil,
            agentRole: nil
        )
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread-spawn source parent must match the Testing thread metadata parent"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: fixture.snapshot,
                turns: [fixture.turn],
                metadata: spawnMetadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var gitMetadata = fixture.metadata
        gitMetadata.gitInfo = .init(sha: "abc123")
        var gitSnapshot = fixture.snapshot
        gitSnapshot.presentFields.remove(.gitInfo)
        let gitFixture = try CodexAppServerTestStoredThread(
            snapshot: gitSnapshot,
            turns: [fixture.turn],
            metadata: gitMetadata,
            runtimeMetadata: fixture.runtimeMetadata,
            isArchived: false
        )
        var explicitNullGitInfo = gitFixture.snapshot
        explicitNullGitInfo.gitInfo = nil
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread snapshot Git metadata must match the Testing thread metadata"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: explicitNullGitInfo,
                turns: [fixture.turn],
                metadata: gitFixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var fractionalCreationTime = fixture.snapshot
        fractionalCreationTime.createdAt = Date(timeIntervalSince1970: 10.5)
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread creation time must be representable as whole Unix seconds"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: fractionalCreationTime,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var unsupportedActiveFlag = fixture.snapshot
        unsupportedActiveFlag.status = .active(activeFlags: ["futureFlag"])
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread active flags must use pinned current-v2 values"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: unsupportedActiveFlag,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var emptyMetadata = fixture.metadata
        emptyMetadata.sessionID = "\t"
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "thread session id must not be empty"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: fixture.snapshot,
                turns: [fixture.turn],
                metadata: emptyMetadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        var unsupportedMetadata = fixture.metadata
        unsupportedMetadata.source = .custom(" ")
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "custom thread session source must not be empty"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: fixture.snapshot,
                turns: [fixture.turn],
                metadata: unsupportedMetadata,
                runtimeMetadata: fixture.runtimeMetadata,
                isArchived: false
            )
        }

        let wrongProvider = try makeRuntimeMetadata(
            modelProvider: "other",
            cwd: fixture.workspace
        )
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "runtime model provider must match the thread snapshot"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: fixture.snapshot,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: wrongProvider,
                isArchived: false
            )
        }

        let wrongCWD = try makeRuntimeMetadata(
            cwd: URL(fileURLWithPath: "/tmp/other-workspace", isDirectory: true)
        )
        #expect(
            throws: CodexAppServerTestError.invalidFixture(
                "runtime cwd must match the thread snapshot"
            )
        ) {
            _ = try CodexAppServerTestStoredThread(
                snapshot: fixture.snapshot,
                turns: [fixture.turn],
                metadata: fixture.metadata,
                runtimeMetadata: wrongCWD,
                isArchived: false
            )
        }
    }
}

private struct CodexAppServerStoredThreadFixture {
    var workspace: URL
    var instructions: URL
    var turn: CodexAppServerTestTurn
    var snapshot: CodexThreadSnapshot
    var metadata: CodexAppServerTestThreadMetadata
    var runtimeMetadata: CodexAppServerTestThreadRuntimeMetadata
    var stored: CodexAppServerTestStoredThread
}

private func makeStoredThreadFixture(
    historyMode: CodexAppServerTestThreadMetadata.HistoryMode = .legacy
) throws -> CodexAppServerStoredThreadFixture {
    let workspace = URL(fileURLWithPath: "/tmp/codex-kit-fixture", isDirectory: true)
    let instructions = workspace.appending(path: "AGENTS.md", directoryHint: .notDirectory)
    let item = try CodexAppServerTestItem.agentMessage(id: "message-1", text: "Done")
    let turn = try CodexAppServerTestTurn(
        snapshot: .init(
            id: "turn-1",
            state: .completed,
            items: [item.domainProjection]
        ),
        items: [item]
    )
    let snapshot = CodexThreadSnapshot(
        id: "thread-1",
        workspace: workspace,
        preview: "Inspect the change",
        modelProvider: "openai",
        sourceKind: .appServer,
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 20),
        status: .idle,
        ephemeral: false,
        turns: [turn.snapshot]
    )
    let metadata = CodexAppServerTestThreadMetadata(
        sessionID: "session-1",
        cliVersion: "codex-cli-test",
        source: .appServer,
        historyMode: historyMode
    )
    let runtimeMetadata = try makeRuntimeMetadata(
        cwd: workspace,
        runtimeWorkspaceRoots: [workspace],
        instructionSources: [instructions],
        approvalPolicy: .granular(
            sandboxApproval: true,
            rules: false,
            skillApproval: true,
            requestPermissions: false,
            mcpElicitations: true
        ),
        approvalsReviewer: .autoReview,
        sandbox: .workspaceWrite(
            writableRoots: [workspace],
            networkAccess: true,
            excludeTmpdirEnvVar: true,
            excludeSlashTmp: false
        ),
        activePermissionProfile: .init(id: "workspace", extends: "base"),
        reasoningEffort: .high,
        multiAgentMode: .custom("delegate focused work")
    )
    let stored = try CodexAppServerTestStoredThread(
        snapshot: snapshot,
        turns: [turn],
        metadata: metadata,
        runtimeMetadata: runtimeMetadata,
        isArchived: true
    )
    return .init(
        workspace: workspace,
        instructions: instructions,
        turn: turn,
        snapshot: snapshot,
        metadata: metadata,
        runtimeMetadata: runtimeMetadata,
        stored: stored
    )
}

private func makeRuntimeMetadata(
    model: String = "gpt-5-codex",
    modelProvider: String = "openai",
    cwd: URL,
    runtimeWorkspaceRoots: [URL] = [],
    instructionSources: [URL] = [],
    approvalPolicy: CodexAppServerTestThreadRuntimeMetadata.ApprovalPolicy = .never,
    approvalsReviewer: CodexAppServerTestThreadRuntimeMetadata.ApprovalsReviewer = .user,
    sandbox: CodexAppServerTestThreadRuntimeMetadata.SandboxPolicy = .dangerFullAccess,
    activePermissionProfile: CodexAppServerTestThreadRuntimeMetadata.ActivePermissionProfile? = nil,
    reasoningEffort: CodexReasoningEffort? = nil,
    multiAgentMode: CodexAppServerTestThreadRuntimeMetadata.MultiAgentMode = .explicitRequestOnly
) throws -> CodexAppServerTestThreadRuntimeMetadata {
    try .init(
        model: model,
        modelProvider: modelProvider,
        serviceTier: nil,
        cwd: cwd,
        runtimeWorkspaceRoots: runtimeWorkspaceRoots,
        instructionSources: instructionSources,
        approvalPolicy: approvalPolicy,
        approvalsReviewer: approvalsReviewer,
        sandbox: sandbox,
        activePermissionProfile: activePermissionProfile,
        reasoningEffort: reasoningEffort,
        multiAgentMode: multiAgentMode
    )
}

func makeRuntimeTestTurnFixture(
    id: CodexTurnID,
    state: CodexTurnSnapshot.State = .completed
) throws -> CodexAppServerTestTurn {
    try .init(
        snapshot: .init(id: id, state: state),
        items: []
    )
}

func makeRuntimeStoredThreadFixture(
    id: CodexThreadID,
    workspace: URL? = nil,
    name: String? = nil,
    preview: String? = nil,
    model: String = "gpt-5",
    modelProvider: String = "openai",
    source: CodexAppServerTestSessionSource = .cli,
    createdAt: Date = Date(timeIntervalSince1970: 10),
    updatedAt: Date = Date(timeIntervalSince1970: 20),
    recencyAt: Date? = nil,
    status: CodexThreadStatus = .idle,
    ephemeral: Bool = false,
    turns: [CodexAppServerTestTurn] = [],
    isArchived: Bool = false,
    forkedFromID: CodexThreadID? = nil
) throws -> CodexAppServerTestStoredThread {
    let workspace = workspace
        ?? URL(fileURLWithPath: "/tmp/\(id.rawValue)", isDirectory: true)
    return try .init(
        snapshot: .init(
            id: id,
            workspace: workspace,
            name: name,
            preview: preview ?? id.rawValue,
            modelProvider: modelProvider,
            sourceKind: source.sourceKind,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            status: status,
            ephemeral: ephemeral,
            turns: turns.map(\.snapshot)
        ),
        turns: turns,
        metadata: .init(
            sessionID: "session-\(id.rawValue)",
            forkedFromID: forkedFromID,
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

struct AppServerKitTestThreadFixture {
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
    var turns: [AppServerKitTestTurnFixture]?

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
        turns: [AppServerKitTestTurnFixture]? = nil
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

    func storedThread(model: String? = nil) throws -> CodexAppServerTestStoredThread {
        let source = sourceKind?.testSessionSource ?? .appServer
        return try makeRuntimeStoredThreadFixture(
            id: id,
            workspace: workspace,
            name: name,
            preview: preview,
            model: model ?? "gpt-5",
            modelProvider: modelProvider ?? "openai",
            source: source,
            createdAt: createdAt ?? Date(timeIntervalSince1970: 10),
            updatedAt: updatedAt ?? createdAt ?? Date(timeIntervalSince1970: 20),
            recencyAt: recencyAt,
            status: status ?? .idle,
            ephemeral: ephemeral ?? false,
            turns: try (turns ?? []).map { try $0.testTurn }
        )
    }
}

struct AppServerKitTestTurnFixture {
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

    var testTurn: CodexAppServerTestTurn {
        get throws {
            let items = try items.map { try $0.testItem }
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
    }
}

extension CodexAppServerTestTransport {
    func enqueueThreadStart(threadID: String, model: String? = nil) throws {
        try enqueueThreadStart(
            AppServerKitTestThreadFixture(id: .init(rawValue: threadID))
                .storedThread(model: model)
        )
    }

    func enqueueThreadResume(
        _ thread: AppServerKitTestThreadFixture,
        model: String? = nil
    ) throws {
        try enqueueThreadResume(try thread.storedThread(model: model))
    }

    func enqueueThreadRead(_ thread: AppServerKitTestThreadFixture) throws {
        try enqueueThreadRead(try thread.storedThread())
    }

    func enqueueTurnStart(
        turnID: String,
        status: String = "inProgress"
    ) throws {
        try enqueueTurnStart(try AppServerKitTestTurnFixture(
            id: .init(rawValue: turnID),
            state: status.testTurnState
        ).testTurn)
    }

    func enqueueReviewStart(
        turnID: String,
        reviewThreadID: String,
        status: CodexTurnStatus = .inProgress,
        items: [CodexThreadItem] = []
    ) throws {
        try enqueueReviewStart(
            try AppServerKitTestTurnFixture(
                id: .init(rawValue: turnID),
                state: status.testTurnState,
                items: items
            ).testTurn,
            reviewThreadID: .init(rawValue: reviewThreadID)
        )
    }

    func enqueueReviewStart(
        _ turn: AppServerKitTestTurnFixture,
        reviewThreadID: String
    ) throws {
        try enqueueReviewStart(
            try turn.testTurn,
            reviewThreadID: .init(rawValue: reviewThreadID)
        )
    }
}

private extension CodexThreadSourceKind {
    var testSessionSource: CodexAppServerTestSessionSource {
        switch self {
        case .cli: .cli
        case .vscode: .vscode
        case .exec: .exec
        case .appServer: .appServer
        case .subAgentReview: .subAgentReview
        case .subAgentCompact: .subAgentCompact
        case .subAgentThreadSpawn:
            .subAgentThreadSpawn(
                parentThreadID: "app-server-kit-testing-parent",
                depth: 0,
                agentPath: nil,
                agentNickname: nil,
                agentRole: nil
            )
        case .subAgentOther: .subAgentOther("app-server-kit-testing")
        case .subAgent: .subAgentMemoryConsolidation
        case .unknown: .unknown
        default: .custom(rawValue)
        }
    }
}

private extension String {
    var testTurnState: CodexTurnSnapshot.State {
        switch self {
        case "inProgress", "running": .inProgress
        case "completed": .completed
        case "interrupted": .interrupted
        default: .unknown(rawValue: self, error: nil)
        }
    }
}

private extension CodexTurnStatus {
    var testTurnState: CodexTurnSnapshot.State {
        switch self {
        case .inProgress: .inProgress
        case .completed: .completed
        case .interrupted: .interrupted
        case .failed: .failed(.init(message: "Testing review failure"))
        case .unknown(let rawValue): .unknown(rawValue: rawValue, error: nil)
        }
    }
}

private extension CodexThreadItem {
    var testItem: CodexAppServerTestItem {
        get throws {
            switch (kind, content) {
            case (.userMessage, .message(let message)):
                try .userMessage(id: id, text: message.text)
            case (.agentMessage, .message(let message)):
                try .agentMessage(id: id, text: message.text, phase: message.phase)
            case (.plan, .plan(let text)):
                try .plan(id: id, text: text)
            case (.reasoning, .reasoning(let reasoning)):
                try .reasoning(id: id, summary: reasoning.summary, content: reasoning.content)
            case (.enteredReviewMode, .log(let review)):
                try .enteredReviewMode(id: id, review: review)
            case (.exitedReviewMode, .log(let review)):
                try .exitedReviewMode(id: id, review: review)
            case (.contextCompaction, .contextCompaction):
                try .contextCompaction(id: id)
            default:
                throw CodexAppServerTestError.invalidFixture(
                    "Unsupported AppServerKit current-v2 test item \(kind.rawValue)."
                )
            }
        }
    }
}
