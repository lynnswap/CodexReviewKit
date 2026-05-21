# CodexReviewKit

CodexReviewKit is the native macOS companion app for Codex review.

Launch `ReviewMonitor.app`, register its MCP endpoint with Codex, then run
reviews through the `codex_review` tools while the app keeps the review state
visible.

## Quick Start

1. Launch `ReviewMonitor.app`.

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
   - `review_list`
   - `review_read`
   - `review_cancel`

## What Runs Locally

- `ReviewMonitor.app` shows review jobs, output, and findings.
- `http://localhost:9417/mcp` is the app-managed MCP endpoint.
- `codex app-server` runs behind ReviewMonitor as the live review backend.
- `~/.codex_review` is the dedicated Codex home used by ReviewMonitor.

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
separate from ReviewMonitor's dedicated runtime home at `~/.codex_review`.

## More Detail

- [Architecture](Docs/architecture.md): package boundaries, runtime flow, and
  test responsibilities.
- [MCP reference](Docs/mcp.md): tool schemas, discovery resources, session
  behavior, and runtime files.
