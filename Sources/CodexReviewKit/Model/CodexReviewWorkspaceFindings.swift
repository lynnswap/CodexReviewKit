import Foundation

package struct CodexReviewWorkspaceFindingEntry: Equatable, Sendable {
    package var threadID: String
    package var targetSummary: String?
    package var priority: Int?
    package var title: String
    package var body: String
    package var locationText: String?

    package init(
        threadID: String,
        targetSummary: String? = nil,
        priority: Int? = nil,
        title: String,
        body: String,
        locationText: String? = nil
    ) {
        self.threadID = threadID
        self.targetSummary = targetSummary
        self.priority = priority
        self.title = title
        self.body = body
        self.locationText = locationText
    }
}

@MainActor
package struct CodexReviewWorkspaceFindingsIndex {
    private let workspaces: [CodexReviewWorkspace]
    private let jobsByWorkspaceCWD: [String: [CodexReviewJob]]

    package init(store: CodexReviewStore) {
        self.workspaces = store.orderedWorkspaces
        self.jobsByWorkspaceCWD = Dictionary(grouping: store.orderedJobs, by: \.cwd)
    }

    package func entries(forWorkspaceCWDs workspaceCWDs: [String]) -> [CodexReviewWorkspaceFindingEntry] {
        let workspacesByCWD = Dictionary(
            uniqueKeysWithValues: workspaces.map { ($0.cwd, $0) }
        )
        return workspaceCWDs
            .compactMap { workspacesByCWD[$0] }
            .flatMap(entries(in:))
    }

    private func entries(in workspace: CodexReviewWorkspace) -> [CodexReviewWorkspaceFindingEntry] {
        let jobs = jobsByWorkspaceCWD[workspace.cwd, default: []]
        return jobs.flatMap { job -> [CodexReviewWorkspaceFindingEntry] in
            guard let result = job.core.output.reviewResult,
                  result.state == .hasFindings
            else {
                return []
            }
            let threadID = workspaceFindingThreadID(for: job)
            return result.findings.map { finding in
                CodexReviewWorkspaceFindingEntry(
                    threadID: threadID,
                    targetSummary: job.targetSummary,
                    priority: finding.priority,
                    title: finding.title,
                    body: finding.body,
                    locationText: locationText(for: finding.location, in: workspace)
                )
            }
        }
    }

    private func locationText(
        for location: ParsedReviewResult.Finding.Location?,
        in workspace: CodexReviewWorkspace
    ) -> String? {
        guard let location else {
            return nil
        }

        let path = workspaceRelativePath(location.path, in: workspace) ?? location.path
        return "\(path):\(location.startLine)-\(location.endLine)"
    }

    private func workspaceRelativePath(
        _ path: String,
        in workspace: CodexReviewWorkspace
    ) -> String? {
        guard path.hasPrefix("/"), workspace.cwd.hasPrefix("/") else {
            return nil
        }
        let workspaceURL = standardizedFileURL(workspace.cwd, isDirectory: true)
        let fileURL = standardizedFileURL(path, isDirectory: false)
        let workspaceComponents = workspaceURL.pathComponents
        let fileComponents = fileURL.pathComponents
        guard fileComponents.count > workspaceComponents.count,
              fileComponents.starts(with: workspaceComponents)
        else {
            return nil
        }
        return fileComponents
            .dropFirst(workspaceComponents.count)
            .joined(separator: "/")
    }

    private func standardizedFileURL(_ path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func workspaceFindingThreadID(for job: CodexReviewJob) -> String {
        job.core.run.reviewThreadID?.nilIfEmpty ?? job.core.run.threadID?.nilIfEmpty ?? job.id
    }
}
