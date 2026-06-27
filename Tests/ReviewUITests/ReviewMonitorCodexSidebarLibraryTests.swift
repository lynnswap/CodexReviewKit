import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Testing
@_spi(PreviewSupport) @testable import ReviewUI

@Suite("ReviewMonitor Codex sidebar library")
@MainActor
struct ReviewMonitorCodexSidebarLibraryTests {
    @Test func buildsSidebarSectionsFromCodexDataKitFetchResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let app = try makeDirectory("App", in: repo)
        let tools = try makeDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(
                    id: "thread-app",
                    workspace: app,
                    name: "App chat",
                    updatedAt: Date(timeIntervalSince1970: 3_000)
                ),
                .init(
                    id: "thread-tools",
                    workspace: tools,
                    name: "Tools chat",
                    updatedAt: Date(timeIntervalSince1970: 2_000)
                ),
            ]
        ))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()

        let section = try #require(library.sections.first)
        let appWorkspace = try #require(section.workspaces.first)
        let appChat = try #require(appWorkspace.chats.first)
        let resolvedAppPath = app.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedToolsPath = tools.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(library.sections.count == 1)
        #expect(section.title == repo.lastPathComponent)
        #expect(section.selection.workspaceCWDs == [resolvedAppPath, resolvedToolsPath])
        #expect(section.workspaces.map(\.title) == ["App", "Tools"])
        #expect(section.chats.map(\.title) == ["App chat", "Tools chat"])
        #expect(appChat === library.chat(id: CodexThreadID(rawValue: "thread-app")))
    }
}

private func makeDirectory(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeGitRepository() throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}
