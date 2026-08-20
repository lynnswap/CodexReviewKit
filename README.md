# CodexReviewKit

CodexReviewKit is the native macOS companion app for Codex review.

Launch `CodexReviewMonitor.app`, register its MCP endpoint with Codex, then run
reviews through the `codex_review` tools while the app keeps the review state
visible.

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

- `CodexReviewMonitor.app` shows review jobs, output, and findings.
- `http://localhost:9417/mcp` is the app-managed MCP endpoint.
- `codex app-server` runs behind CodexReviewMonitor as the live review backend.
- `~/.codex_review` is the dedicated Codex home used by CodexReviewMonitor.

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

## More Detail

- [Architecture](Docs/architecture.md): package boundaries, runtime flow, and
  test responsibilities.
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
