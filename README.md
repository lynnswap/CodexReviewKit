# CodexReviewKit

CodexReviewKit is the native macOS companion app for Codex review. The same
Swift package also distributes reusable app-server, observable model, and test
runtime libraries for macOS apps and tools that work with Codex.

Launch `CodexReviewMonitor.app`, register its MCP endpoint with Codex, then run
reviews through the `codex_review` tools while the app keeps the review state
visible.

## Requirements

- macOS 26 or later.
- Swift 6.3 or later.
- A local `codex` executable when using ReviewMonitor or a real app-server
  process. `CodexAppServerKitTesting` does not launch one.

## Add The Package

Add CodexReviewKit as a Swift package dependency:

```swift
dependencies: [
    .package(
        url: "https://github.com/lynnswap/CodexReviewKit.git",
        branch: "main"
    ),
]
```

Then select the library products your target needs:

```swift
.product(name: "CodexAppServerKit", package: "CodexReviewKit"),
.product(name: "CodexDataKit", package: "CodexReviewKit"),
.product(name: "CodexAppServerKitTesting", package: "CodexReviewKit"),
```

- `CodexAppServerKit` provides domain APIs for app-server connections, threads,
  responses, reviews, models, accounts, and login.
- `CodexDataKit` provides observable app-server-backed model objects and fetch
  APIs on top of `CodexAppServerKit`.
- `CodexAppServerKitTesting` provides a deterministic in-memory app-server test
  runtime without launching a real process.

## Quick Start

1. Launch `CodexReviewMonitor.app`.

2. Register the local MCP endpoint in the client you use.

   Codex CLI:

   ```bash
   codex mcp add codex_review --url http://localhost:9417/mcp
   ```

   Claude Code:

   ```bash
   claude mcp add --transport http codex_review http://localhost:9417/mcp
   ```

3. Use the review tools from Codex:

   - `review_start`
   - `review_await`
   - `review_list`
   - `review_read`
   - `review_cancel`

## What Runs Locally

- `CodexReviewMonitor.app` shows review runs, CodexChat logs, and findings.
- `http://localhost:9417/mcp` is the app-managed MCP endpoint.
- `codex app-server` runs behind CodexReviewMonitor as the live review backend.
- `~/.codex_review` is the dedicated Codex home used by CodexReviewMonitor.

## CodexAppServerKit

`CodexAppServerKit` is the Swift library product for working with a local
`codex app-server` process. It owns the stdio JSON-RPC transport, app-server
handshake, typed request DTOs, and a domain-oriented public API for sessions,
thread IDs, turn IDs, prompts, responses, response streams, transcripts, models,
accounts, and login flows.

The public API is centered on a `CodexAppServer` value that is initialized and
kept for the lifetime of the app-server connection:

```swift
import CodexAppServerKit

let appServer = try await CodexAppServer()
let thread = try await appServer.startThread(in: workspaceURL)
let result = try await thread.respond(to: "Review this workspace.")
await appServer.close()
```

`CodexReviewAppServer` builds on that lower-level app-server boundary and keeps
only ReviewMonitor-specific `review/start` orchestration and review event
conversion.

See the [CodexAppServerKit README](Sources/CodexAppServerKit/README.md) for the
standalone SDK surface, including thread-level streams for messages,
transcripts, log entries, and in-flight response controls such as steer, queue,
and interrupt. The [CodexDataKit README](Sources/CodexDataKit/README.md) covers
model containers, fetch requests, sectioning, SwiftUI queries, and ownership.
The [`CodexReviewKitProductConsumer`](Fixtures/CodexReviewKitProductConsumer)
fixture builds, links, and runs all three products without `@testable import`.

## Timeout Setup

Long reviews can exceed the default MCP client timeout. `codex mcp add` does
not currently expose timeout flags, so add them manually after registration:

```toml
[mcp_servers.codex_review]
url = "http://localhost:9417/mcp"
startup_timeout_sec = 1200.0
tool_timeout_sec = 1200.0
```

This config belongs to the Codex client that calls the MCP server. It is
separate from CodexReviewMonitor's dedicated runtime home at `~/.codex_review`.

Claude Code also has an MCP tool idle timeout for remote MCP tools. To allow
long-running reviews that may stay quiet for more than the default idle window,
set `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` in milliseconds in Claude Code's
settings, for example 40 minutes:

```json
{
  "env": {
    "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT": "2400000"
  }
}
```

This Claude Code setting is process-wide. It is not scoped to the
`codex_review` MCP server, so the same idle timeout applies to all MCP tools
used by that Claude Code session.

## More Detail

- [API documentation](https://lynnswap.github.io/CodexReviewKit/): generated
  DocC for every public library product.
- [Architecture](Docs/architecture.md): package boundaries, runtime flow, and
  test responsibilities.
- [CodexKit integration design](Docs/codexkit-integration.md): the canonical
  target topology, compatibility contract, deletion scope, and migration test
  plan.
- [MCP reference](Docs/mcp.md): tool schemas, discovery resources, session
  behavior, and runtime files.

## Local Release

Public macOS archives are built locally so Developer ID certificates and notary
credentials stay out of CI. The local script signs, notarizes, staples, pushes
the tag from `main`, creates the draft release asset, and then explicitly
dispatches the release verification workflow for that tag. The workflow runs
tests with read-only repository access and publishes the draft release only
after verification succeeds.

```bash
scripts/publish-local-release.sh \
  v0.0.2 \
  --signing-identity "Developer ID Application: Your Team (TEAMID)" \
  --notary-profile "codex-reviewkit"
```

Create the `notarytool` profile in the local Keychain before publishing:

```bash
xcrun notarytool store-credentials codex-reviewkit
```

The release verification workflow also requires the repository variable
`EXPECTED_DEVELOPER_ID_TEAM_ID`. Set it to the Apple Team ID from the
Developer ID Application certificate used by `--signing-identity`. The workflow
will not publish the draft release unless the uploaded DMG and contained app are
signed and notarized for that Team ID.
