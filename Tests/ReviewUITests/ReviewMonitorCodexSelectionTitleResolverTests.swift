import CodexAppServerKitTesting
import CodexAppServerKit
import CodexDataKit
import Foundation
import Testing
@testable import ReviewUI

@Suite("ReviewMonitor Codex selection title resolver")
@MainActor
struct ReviewMonitorCodexSelectionTitleResolverTests {
    @Test func resolvesWorkspaceGroupAndChatTitlesFromLoadedCodexModels() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeTitleResolverGitRepository()
        let app = try makeTitleResolverDirectory("App", in: repo)
        let tools = try makeTitleResolverDirectory("Tools", in: repo)
        let appThreadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    try makeTitleResolverStoredThread(
                        id: appThreadID,
                        workspace: app,
                        name: "App review",
                        updatedAt: Date(timeIntervalSince1970: 3_000)
                    ),
                    try makeTitleResolverStoredThread(
                        id: "thread-tools",
                        workspace: tools,
                        name: "Tools review",
                        updatedAt: Date(timeIntervalSince1970: 2_000)
                    ),
                ]
            ))

        try await loadReviewChats(in: context)
        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)

        let appWorkspace = try #require(context.registeredModel(for: workspaceID(for: app)))
        let workspaceGroup = try #require(appWorkspace.workspaceGroup)
        let appPath = app.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(
            resolver.titlePresentation(for: .workspaceGroup(workspaceGroup.id))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: repo.lastPathComponent,
                    subtitle: "2 workspaces"
                ))
        #expect(
            resolver.titlePresentation(for: .chat(appThreadID))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: "App review",
                    subtitle: appPath
                ))
    }

    @Test func resolvesSingleWorkspaceGroupSubtitleFromWorkspacePath() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeTitleResolverGitRepository()

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    try makeTitleResolverStoredThread(
                        id: "thread-repo",
                        workspace: repo,
                        name: "Repo review",
                        updatedAt: Date(timeIntervalSince1970: 1_000)
                    )
                ]
            ))

        try await loadReviewChats(in: context)
        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)

        let workspace = try #require(context.registeredModel(for: workspaceID(for: repo)))
        let workspaceGroup = try #require(workspace.workspaceGroup)
        let repoPath = repo.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(
            resolver.titlePresentation(for: .workspaceGroup(workspaceGroup.id))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: repo.lastPathComponent,
                    subtitle: repoPath
                ))
    }

    @Test func resolvesChatOutsideGitRepositoryButDoesNotTreatUnknownChatAsLoaded() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let floatingThreadID = CodexThreadID(rawValue: "thread-floating")
        let workspace = try makeTitleResolverDirectory(
            "Floating",
            in: FileManager.default.temporaryDirectory
        )

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    try makeTitleResolverStoredThread(
                        id: floatingThreadID,
                        workspace: workspace,
                        name: "Floating review",
                        preview: "Uncategorized preview",
                        updatedAt: Date(timeIntervalSince1970: 1_000)
                    )
                ]
            ))

        try await loadReviewChats(in: context)
        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)

        #expect(
            resolver.titlePresentation(for: .chat(floatingThreadID))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: "Floating review",
                    subtitle: workspace.standardizedFileURL.resolvingSymlinksInPath().path
                ))
        #expect(
            resolver.titlePresentation(for: .chat(CodexThreadID(rawValue: "thread-missing"))) == nil
        )
    }

    @Test func returnsNilForMissingWorkspaceGroupAndEmptySelection() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        try await loadReviewChats(in: context)
        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)

        #expect(resolver.titlePresentation(for: nil) == nil)
        #expect(
            resolver.titlePresentation(for: .workspaceGroup(CodexWorkspaceGroupID(rawValue: "missing"))) == nil
        )
    }
}

@MainActor
private func loadReviewChats(in context: CodexModelContext) async throws {
    let results = context.fetchedResults(
        for: CodexFetchDescriptor<CodexChat>(
            predicate: sourceKindChatPredicate([.subAgentReview]),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        ),
        sectionedBy: .workspaceGroup
    )
    try await results.performFetch()
}

private func sourceKindChatPredicate(_ sourceKinds: [CodexThreadSourceKind]) -> Predicate<CodexChat> {
    #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.sourceKind != nil
            && sourceKinds.contains(chat.sourceKind!)
    }
}

private func workspaceID(for url: URL) -> CodexWorkspaceID {
    CodexWorkspaceID(rawValue: url.standardizedFileURL.resolvingSymlinksInPath().path)
}

private func makeTitleResolverStoredThread(
    id: CodexThreadID,
    workspace: URL,
    name: String,
    preview: String? = nil,
    updatedAt: Date
) throws -> CodexAppServerTestStoredThread {
    let source = CodexAppServerTestSessionSource.subAgentReview
    return try .init(
        snapshot: .init(
            id: id,
            workspace: workspace,
            name: name,
            preview: preview ?? name,
            modelProvider: "openai",
            sourceKind: source.sourceKind,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            status: .idle,
            ephemeral: false,
            turns: []
        ),
        turns: [],
        metadata: .init(
            sessionID: "title-resolver-\(id.rawValue)",
            cliVersion: "codex-review-kit-tests",
            source: source
        ),
        runtimeMetadata: .init(
            model: "gpt-5",
            modelProvider: "openai",
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

private func makeTitleResolverDirectory(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTitleResolverGitRepository() throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}
