# CodexReviewKit

CodexReviewMonitor is a macOS app for running Codex reviews. Start reviews from
Codex or Claude Code through MCP, then read the output and findings in the app.
It requires macOS 26 or newer and the Codex CLI installed on your Mac.

## Quick start

1. Download the signed and notarized DMG from the
   [latest release](https://github.com/lynnswap/CodexReviewKit/releases/latest).
2. Open `CodexReviewMonitor_<version>.dmg`, drag `CodexReviewMonitor.app` to
   Applications, and launch it.
3. Sign in from the app with **Sign in with ChatGPT**, or choose
   **Sign in another way** to use an API key.
4. Register the app's MCP endpoint with your client.

   Codex CLI:

   ```bash
   codex mcp add codex_review --url http://localhost:9417/mcp
   ```

   Claude Code:

   ```bash
   claude mcp add --transport http codex_review http://localhost:9417/mcp
   ```

5. Ask your client to review a repository. It uses `review_start` to start a job
   and `review_await` if the review needs more time. `review_list`, `review_read`,
   and `review_cancel` let you inspect or cancel jobs.

Keep the app running while you use the tools. It hosts
`http://localhost:9417/mcp` and runs `codex app-server` for the reviews.
ReviewMonitor uses `~/.codex_review` as its Codex home.

### Allow time for long reviews

Add these timeout settings to the calling Codex client's configuration after
registering the endpoint. `codex mcp add` does not expose timeout flags.

```toml
[mcp_servers.codex_review]
url = "http://localhost:9417/mcp"
startup_timeout_sec = 1200.0
tool_timeout_sec = 1200.0
```

This is the client's configuration, separate from ReviewMonitor's
`~/.codex_review` home. See the [MCP reference](Docs/mcp.md) for tool arguments,
results, and session behavior.

## Update Codex

ReviewMonitor checks for Codex updates at launch and every eight hours. You can
also check in **Settings → Updates → Check for Updates**, which shows the last
check time. A manual check only checks availability; it keeps the automatic
schedule and leaves installation to you.
Settings distinguishes unsupported installations and failed checks from
**Up to Date**.

Choose **Update** in the sidebar when a new version is available. If reviews are
running, choose **Update After Reviews** to finish them first, or
**Stop Reviews and Update** to cancel them and update now. New review requests
wait in ReviewMonitor's queue and resume after Codex restarts. The app and MCP
sessions stay open, and you do not need to resubmit requests.

Automatic installation supports the stable Homebrew Codex cask and standalone
installations selected through their stable launcher. Other installations show
manual update guidance when an update is available. Checks and installation use
the selected CLI's installation home, including custom standalone homes;
reviews use `~/.codex_review`.

If installation fails but Codex restarts, queued reviews resume and Settings
shows the error. If Codex cannot restart, the queue stays available and **Retry**
attempts recovery without reinstalling. Quitting the app cancels queued reviews
and waits for any installation already in progress.

## Build from source

On an Apple silicon Mac with Xcode 26.4 or newer and Python 3.10 or newer, run
this command from the repository root:

```bash
python3 scripts/build_review_monitor.py
```

It creates `dist/CodexReviewMonitor_yymmdd_hhmm.dmg` with an ad-hoc signature for
local use. You can keep ReviewMonitor running during the build. Once reviews
finish, quit the app, open the DMG, and drag the new app to Applications. Choose
**Replace**, then launch it.

See [local build details](Docs/releases.md#local-builds) for signing identities,
build caches, and packaging behavior.

## Documentation

- [Architecture](Docs/architecture.md): targets, review flow, and runtime updates.
- [MCP reference](Docs/mcp.md): tool arguments, results, and runtime files.
- [Release guide](Docs/releases.md): signing, validation, and publication.
