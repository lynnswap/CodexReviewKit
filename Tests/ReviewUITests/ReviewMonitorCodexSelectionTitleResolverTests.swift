import CodexAppServerKitTesting
import CodexKit
import Foundation
import Testing
@testable import ReviewUI

@Suite("ReviewMonitor Codex selection title resolver")
@MainActor
struct ReviewMonitorCodexSelectionTitleResolverTests {
    @Test func resolvesWorkspaceGroupWorkspaceAndChatTitlesFromLoadedCodexModels() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeTitleResolverGitRepository()
        let app = try makeTitleResolverDirectory("App", in: repo)
        let tools = try makeTitleResolverDirectory("Tools", in: repo)
        let appThreadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: appThreadID,
                        workspace: app,
                        name: "App review",
                        updatedAt: Date(timeIntervalSince1970: 3_000)
                    ),
                    .init(
                        id: "thread-tools",
                        workspace: tools,
                        name: "Tools review",
                        updatedAt: Date(timeIntervalSince1970: 2_000)
                    ),
                ]
            ))

        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)
        try await resolver.refresh()

        let appWorkspace = try #require(context.model(for: workspaceID(for: app)))
        let workspaceGroup = try #require(appWorkspace.workspaceGroup)
        let appPath = app.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(
            resolver.titlePresentation(for: .workspaceGroup(workspaceGroup.id))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: repo.lastPathComponent,
                    subtitle: "2 workspaces"
                ))
        #expect(
            resolver.titlePresentation(for: .workspace(appWorkspace.id))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: "App",
                    subtitle: appPath
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
                    .init(
                        id: "thread-repo",
                        workspace: repo,
                        name: "Repo review",
                        updatedAt: Date(timeIntervalSince1970: 1_000)
                    )
                ]
            ))

        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)
        try await resolver.refresh()

        let workspace = try #require(context.model(for: workspaceID(for: repo)))
        let workspaceGroup = try #require(workspace.workspaceGroup)
        let repoPath = repo.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(
            resolver.titlePresentation(for: .workspaceGroup(workspaceGroup.id))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: repo.lastPathComponent,
                    subtitle: repoPath
                ))
    }

    @Test func resolvesUncategorizedChatButDoesNotTreatUnknownChatAsLoaded() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let floatingThreadID = CodexThreadID(rawValue: "thread-floating")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: floatingThreadID,
                        name: "Floating review",
                        preview: "Uncategorized preview",
                        updatedAt: Date(timeIntervalSince1970: 1_000)
                    )
                ]
            ))

        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)
        try await resolver.refresh()

        #expect(
            resolver.titlePresentation(for: .chat(floatingThreadID))
                == ReviewMonitorCodexSelectionTitlePresentation(
                    title: "Floating review",
                    subtitle: ""
                ))
        #expect(
            resolver.titlePresentation(for: .chat(CodexThreadID(rawValue: "thread-missing"))) == nil
        )
    }

    @Test func returnsNilForMissingWorkspaceGroupWorkspaceAndEmptySelection() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let resolver = ReviewMonitorCodexSelectionTitleResolver(modelContext: context)
        try await resolver.refresh()

        #expect(resolver.titlePresentation(for: nil) == nil)
        #expect(
            resolver.titlePresentation(for: .workspaceGroup(CodexWorkspaceGroupID(rawValue: "missing"))) == nil
        )
        #expect(
            resolver.titlePresentation(for: .workspace(CodexWorkspaceID(rawValue: "/missing"))) == nil
        )
    }
}

private func workspaceID(for url: URL) -> CodexWorkspaceID {
    CodexWorkspaceID(rawValue: url.standardizedFileURL.resolvingSymlinksInPath().path)
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
