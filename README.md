# CodexReviewKit

CodexReviewMonitor runs Codex reviews on your Mac. Start a review from Codex or
Claude Code through MCP and read its findings in the app. You'll need macOS 26
or newer and the Codex CLI.

## Quick start

1. Download the signed and notarized DMG from the
   [latest release](https://github.com/lynnswap/CodexReviewKit/releases/latest).
   Open the DMG, drag `CodexReviewMonitor.app` to Applications, and launch it.
2. Sign in with ChatGPT, or choose **Sign in another way** to use an API key.
   ReviewMonitor uses `~/.codex_review` as its default Codex home.
3. Register ReviewMonitor with your client.

   **Codex CLI**

   ```bash
   codex mcp add codex_review --url http://localhost:9417/mcp
   ```

   **Claude Code**

   ```bash
   claude mcp add --transport http codex_review http://localhost:9417/mcp
   ```

4. Keep ReviewMonitor running and ask your client to review a repository.

### Allow time for long reviews

For long reviews, set the timeouts in the calling Codex client's configuration
after registering the endpoint.

```toml
[mcp_servers.codex_review]
url = "http://localhost:9417/mcp"
startup_timeout_sec = 1200.0
tool_timeout_sec = 1200.0
```

## Update Codex

ReviewMonitor checks for updates at launch and every eight hours. To check
manually, open **Settings → Updates → Check for Updates**.

Choose **Update** in the sidebar. If reviews are running, choose **Update After
Reviews** to finish them first or **Stop Reviews and Update** to cancel them.
New requests stay queued and resume when Codex restarts. If it fails to
restart, choose **Retry** to resume without reinstalling.

Automatic installation supports the stable Homebrew cask and standalone
installations selected through their stable launcher. For other installations,
follow the manual update instructions in the app.

## Build from source

Run this command from the repository root to create a local DMG in `dist/`.
[Build requirements](Docs/releases.md#local-builds)

```bash
python3 scripts/build_review_monitor.py
```

## Documentation

- [Architecture](Docs/architecture.md)
- [MCP reference](Docs/mcp.md)
- [Release and build guide](Docs/releases.md)
