import MCP

struct HelpResource: Sendable {
    var uri: String
    var name: String
    var description: String
    var content: String

    var resource: Resource {
        Resource(
            name: name,
            uri: uri,
            description: description,
            mimeType: "text/markdown"
        )
    }
}

let helpResources: [HelpResource] = [
    .init(
        uri: "codex-review://help/overview",
        name: "Codex Review MCP Overview",
        description: "Overview of the Codex review MCP tools.",
        content: """
        # Codex Review MCP

        Use `review_start` to run a review, `review_await` to continue waiting for long-running runs, then `review_read`, `review_list`, or `review_cancel` to inspect or control review runs.
        """
    ),
    .init(
        uri: "codex-review://help/tools/review_start",
        name: "review_start",
        description: "Input shape for starting a Codex review.",
        content: """
        # review_start

        Required arguments: `cwd` and `target`.

        Supported target types: `uncommittedChanges`, `baseBranch`, `commit`, and `custom`.
        """
    ),
    .init(
        uri: "codex-review://help/tools/review_await",
        name: "review_await",
        description: "Wait for a running Codex review run.",
        content: """
        # review_await

        Required argument: `runId`.

        Use this after `review_start` returns a running run. The tool waits for the run to finish and returns the final review when available.
        """
    ),
    .init(
        uri: "codex-review://help/targets/uncommittedChanges",
        name: "Target: uncommittedChanges",
        description: "Review uncommitted workspace changes.",
        content: """
        # Target: uncommittedChanges

        `{"type":"uncommittedChanges"}`
        """
    ),
    .init(
        uri: "codex-review://help/targets/baseBranch",
        name: "Target: baseBranch",
        description: "Review changes against a base branch.",
        content: """
        # Target: baseBranch

        `{"type":"baseBranch","branch":"main"}`
        """
    ),
    .init(
        uri: "codex-review://help/targets/commit",
        name: "Target: commit",
        description: "Review a specific commit.",
        content: """
        # Target: commit

        `{"type":"commit","sha":"abc1234","title":"Optional title"}`
        """
    ),
    .init(
        uri: "codex-review://help/targets/custom",
        name: "Target: custom",
        description: "Run a review with custom instructions.",
        content: """
        # Target: custom

        `{"type":"custom","instructions":"Free-form review instructions"}`
        """
    ),
]

let helpResourceTemplates: [Resource.Template] = [
    .init(
        uriTemplate: "codex-review://help/tools/{tool}",
        name: "Codex Review tool help",
        description: "Help for a Codex Review MCP tool.",
        mimeType: "text/markdown"
    ),
    .init(
        uriTemplate: "codex-review://help/targets/{target}",
        name: "Codex Review target help",
        description: "Help for a Codex Review target shape.",
        mimeType: "text/markdown"
    ),
]
