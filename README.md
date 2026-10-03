# CodexReviewKit

CodexReviewKit is the native macOS companion app for Codex review.

Launch `CodexReviewMonitor.app`, register its MCP endpoint with Codex, then run
reviews through the `codex_review` tools while the app keeps the review state
visible.

## Quick Start

1. Download the signed and notarized DMG from the
   [latest release](https://github.com/lynnswap/CodexReviewKit/releases/latest).

2. Open `CodexReviewMonitor_<version>.dmg`, drag `CodexReviewMonitor.app` to
   Applications, then launch the app.

3. Register the local MCP endpoint in the client you use.

   Codex CLI:

   ```bash
   codex mcp add codex_review --url http://localhost:9417/mcp
   ```

   Claude Code:

   ```bash
   claude mcp add --transport http codex_review http://localhost:9417/mcp
   ```

4. Use the review tools from Codex:

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

## Codex Updates

ReviewMonitor checks the selected Codex installation at launch and every eight
hours. Use **Settings → Updates → Check for Updates** for a manual check and its
last-check time. Manual checks do not change the automatic schedule and do not
install an update. Unsupported installations and failed checks are reported
separately from **Up to Date**. Automatic installation supports the stable
Homebrew Codex cask and standalone installations selected through their stable
launcher. Update checks and installation use the selected CLI's installation
home, including custom standalone homes; reviews keep using `~/.codex_review`.
When a newer version is available for an installation that cannot be updated
automatically, Settings reports **Update Available** with manual update guidance.

When an update is available, choose **Update** in the sidebar toolbar. During a
review, **Update After Reviews** lets current reviews finish and queues new
requests inside ReviewMonitor. **Stop Reviews and Update** cancels current
reviews and updates immediately. ReviewMonitor and its MCP sessions stay open;
queued requests resume after Codex restarts, without being resubmitted.
The toolbar shows a spinner and the update stage while Codex is stopping,
installing, or restarting.

If updating fails but Codex can restart, queued reviews resume and the error
remains visible in Settings. If Codex cannot restart, the queue is retained and
**Retry** in the sidebar attempts runtime recovery without reinstalling. Explicitly
quitting the app cancels queued reviews; an installation already in progress is
allowed to finish before the app exits.

To investigate UI responsiveness during updates, enable
`REVIEW_MONITOR_SIMULATE_CODEX_UPDATE=1` in the Xcode scheme's **Run → Arguments →
Environment Variables**, then launch the app. The normal **Update** button appears
after a one-second simulated check. Installation waits ten seconds using the same
subprocess runner as a real update, while the existing Codex runtime stops and
restarts normally. Codex and Homebrew packages are not changed. Settings reports
**Up to Date** afterward; relaunch the app to repeat the simulation. Use this mode
with the live runtime, with `REVIEW_MONITOR_MOCK_JOBS` and
`REVIEW_MONITOR_REVIEW_MODE` disabled.

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

## Build from Source

To build a local DMG from the current checkout, run from the repository root
using Python 3.10 or newer:

```bash
python3 scripts/build_review_monitor.py
```

The command creates `dist/CodexReviewMonitor_yymmdd_hhmm.dmg`, using the local
build-start time, and stages the signed app in `dist/arm64`. It applies an ad-hoc
hardened-runtime signature and verifies the DMG's contents. Build caches remain
in `.build` for subsequent builds. The first run prepares the pinned DMG tools
in `.build/release-tools` and may download the locked package dependencies.

Keep CodexReviewMonitor running while building. When the DMG is ready and reviews
have finished, quit the app, open the DMG, and drag `CodexReviewMonitor.app` to
Applications. Choose **Replace**, then launch the installed app. There is no need
to delete the existing app first. Builds started in the same minute replace the
same DMG only after the new image passes validation; older filenames are retained.

The local build requires an Apple silicon Mac and Xcode 26.4 or newer; the app
requires macOS 26 or newer. The command does not modify or launch installed apps.

The default ad-hoc signature is for local use and does not make a redistributable
or notarized app. If the Mac's management policy requires an approved local
identity, pass it explicitly; the command never falls back to another
identity:

```bash
python3 scripts/build_review_monitor.py \
  --signing-identity 'Apple Development: Developer Name (TEAMID)'
```

Device-management policy can still prohibit locally signed apps. The command
does not disable Gatekeeper or remove quarantine metadata.

## More Detail

- [Architecture](Docs/architecture.md): ownership boundaries and runtime flow.
- [MCP reference](Docs/mcp.md): tool schemas, discovery resources, session
  behavior, and runtime files.
- [Release guide](Docs/releases.md): maintainer signing setup, Draft Release
  preparation and publication, validation builds, and repository protection.
