import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation

@main
struct CodexReviewKitProductConsumer {
    @MainActor
    static func main() async throws {
        let workspace = URL(
            fileURLWithPath: "/tmp/codex-reviewkit-product-consumer",
            isDirectory: true
        )
        let assistant = try CodexAppServerTestItem.agentMessage(
            id: "review_rollout_assistant",
            text: "No findings."
        )
        let turn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-fixture",
                state: .completed,
                items: [assistant.domainProjection]
            ),
            items: [assistant]
        )
        let storedThread = try CodexAppServerTestStoredThread(
            snapshot: .init(
                id: "thread-fixture",
                workspace: workspace,
                name: "External product fixture",
                preview: "No findings.",
                modelProvider: "openai",
                source: .subAgent(.review),
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                status: .idle,
                ephemeral: false,
                turns: [turn.snapshot]
            ),
            turns: [turn],
            metadata: .init(
                sessionID: "fixture-session",
                parentThreadID: "fixture-parent-thread",
                cliVersion: "fixture-cli",
                source: .subAgentReview,
                gitInfo: .init(
                    sha: "0123456789abcdef",
                    branch: "feature/thread-provenance",
                    originURL: "git@github.com:lynnswap/CodexReviewKit.git"
                )
            ),
            runtimeMetadata: .init(
                model: "gpt-5-codex",
                modelProvider: "openai",
                serviceTier: nil,
                cwd: workspace,
                runtimeWorkspaceRoots: [workspace],
                instructionSources: [],
                approvalPolicy: .never,
                approvalsReviewer: .user,
                sandbox: .workspaceWrite(
                    writableRoots: [workspace],
                    networkAccess: false,
                    excludeTmpdirEnvVar: false,
                    excludeSlashTmp: false
                ),
                activePermissionProfile: nil,
                reasoningEffort: .high,
                multiAgentMode: .explicitRequestOnly
            ),
            isArchived: false
        )
        let deadlineClock = CodexAppServerTestDeadlineClock()
        let configuration = CodexAppServer.Configuration(
            serverRequestHandler: { request in
                switch request {
                case .commandExecutionApproval(let approval):
                    precondition(approval.threadID.isEmpty == false)
                    return .approval(.accept)
                case .userInput(let prompt):
                    return .userInput(.init(answers: prompt.questions.reduce(into: [:]) {
                        $0[$1.id] = .init(answers: [])
                    }))
                default:
                    return try await CodexAppServer.Configuration
                        .defaultServerRequestHandler(request: request)
                }
            }
        )
        let runtime = try await CodexAppServerTestRuntime.start(
            threads: [storedThread],
            configuration: configuration,
            deadlineClock: deadlineClock
        )

        do {
            precondition(runtime.deadlineClock === deadlineClock)
            try await runtime.transport.enqueueAPIKeyLogin()
            try await runtime.server.login(apiKey: "fixture-api-key")
            let loginRequests = await runtime.transport.recordedRequests(for: .accountLoginStart)
            precondition(loginRequests.count == 1)

            let configURL = workspace.appendingPathComponent("config.toml")
            let configLayer = try CodexAppServerTestConfigurationLayerMetadata(
                source: .user(file: configURL, profile: nil),
                version: "fixture-config-v1"
            )
            let configRead = try CodexAppServerTestConfigurationReadResult(
                configuration: .init(model: "gpt-5-codex"),
                origins: ["model": configLayer],
                layers: [try .init(
                    metadata: configLayer,
                    configuration: .object(["model": .string("gpt-5-codex")])
                )]
            )
            try await runtime.transport.enqueueConfiguration(configRead)
            let configuration = try await runtime.server.configuration()
            precondition(configuration == configRead.configuration)

            let container = CodexModelContainer(appServer: runtime.server)
            let context = container.mainContext
            let reviewSourceKind: CodexThreadSourceKind? = .subAgentReview
            let chats = try await context.fetch(CodexFetchDescriptor<CodexChat>(
                predicate: #Predicate { chat in
                    chat.isArchived == false && chat.sourceKind == reviewSourceKind
                }
            ))
            precondition(chats.map(\.id) == [CodexThreadID(rawValue: "thread-fixture")])

            let chat = chats[0]
            precondition(chat.sessionID == "fixture-session")
            precondition(chat.parentThreadID == "fixture-parent-thread")
            precondition(chat.source == .subAgent(.review))
            precondition(chat.sourceKind == .subAgentReview)
            precondition(chat.gitInfo?.branch == "feature/thread-provenance")
            precondition(chat.gitInfo?.sha == "0123456789abcdef")
            precondition(chat.gitInfo?.originURL == "git@github.com:lynnswap/CodexReviewKit.git")
            try await context.refresh(chat, includeTurns: true)
            let item = chat.items(in: "turn-fixture")[0]
            precondition(item.origin == .reviewRolloutAssistant)
            precondition(item.semanticRelation == .companionOf(.exitedReviewMode))

            let thread = try await runtime.server.resumeThread("thread-fixture")
            _ = try await thread.read(includeTurns: true)
            let requests = await runtime.transport.recordedRequests(for: .threadRead)
            guard let lastRequest = requests.last,
                case .threadRead(let threadID, let includeTurns) = lastRequest.request,
                threadID == "thread-fixture",
                includeTurns
            else {
                preconditionFailure("Expected a semantic thread-read request.")
            }

            let fakeRestartToken = CodexReviewRestartToken(
                id: "fixture-restart-token",
                interruptedIdentity: .init(
                    threadID: "fixture-source-thread",
                    turnID: "fixture-turn"
                )
            )
            let discarded = await runtime.server.discardPreparedReviewRestart(fakeRestartToken)
            precondition(discarded.isEmpty)
            let discardedAll = await runtime.server.discardAllPreparedReviewRestarts()
            precondition(discardedAll.isEmpty)

            let cleanup = await runtime.server.cleanupReview(.init(
                threadID: "thread-fixture",
                turnID: "turn-fixture"
            ))
            precondition(cleanup.attemptedThreadIDs == ["thread-fixture"])
            precondition(cleanup.failures.isEmpty)
        } catch {
            await runtime.close()
            throw error
        }

        await runtime.close()
    }
}
