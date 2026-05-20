# CodexReviewKit

CodexReviewKit provides ReviewMonitor, a native macOS app for running and
monitoring Codex review. ReviewMonitor owns the local MCP endpoint used by
Codex clients.

## Quick Start

1. Launch `ReviewMonitor.app`.

2. Register the app-managed MCP endpoint in your client if needed:

   ```bash
   codex mcp add codex_review --url http://localhost:9417/mcp
   ```

3. Call one of the exposed review tools:

   - `review_start`
   - `review_list`
   - `review_read`
   - `review_cancel`

### Runtime home

ReviewMonitor launches `codex app-server` as the live backend for review tools
and owns the Streamable HTTP MCP endpoint at `http://localhost:9417/mcp`.

### Codex CLI timeout note

`codex mcp add` does not currently expose MCP timeout flags. If you expect
long-running reviews, add the timeout values manually in your client Codex
config after registration. This client-side MCP entry is separate from the
ReviewMonitor backend home described above:

```toml
[mcp_servers.codex_review]
url = "http://localhost:9417/mcp"
startup_timeout_sec = 1200.0
tool_timeout_sec = 1200.0
```

Use your normal `codex mcp add ...` command first, then edit the generated
entry to include the timeout values.

## Architecture

For a concise architecture summary and diagrams, see [Docs/architecture.md](Docs/architecture.md).

## MCP Details

For tool schemas, discovery resources, resource templates, session behavior, and runtime files, see [Docs/mcp.md](Docs/mcp.md).
