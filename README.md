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

## Build from Source

To build, install, and launch CodexReviewMonitor from the current checkout, run
the installer from the repository root:

```bash
./scripts/install_review_monitor.py --launch
```

The installer builds the current checkout, applies an ad-hoc hardened-runtime
signature, validates the app, and deploys it to
`/Applications/CodexReviewMonitor.app`. Installing there requires write access.

The local installer requires macOS 26 or newer, an Apple silicon Mac, and
Xcode 26.4 or newer. The first build may download the package versions locked
by the repository.

Quit CodexReviewMonitor before installing. If the default destination already
exists, the installer stops before building; remove the app manually before
rerunning it. The destination is checked again before deployment. To install
only for the current user, select `~/Applications` explicitly:

```bash
./scripts/install_review_monitor.py \
  --destination ~/Applications/CodexReviewMonitor.app \
  --launch
```

The default ad-hoc signature is for local use and does not make a redistributable
or notarized app. If the Mac's management policy requires an approved local
identity, pass it explicitly; the installer never falls back to another
identity:

```bash
./scripts/install_review_monitor.py \
  --signing-identity 'Apple Development: Developer Name (TEAMID)' \
  --launch
```

Device-management policy can still prohibit locally signed apps. The installer
does not disable Gatekeeper or remove quarantine metadata.

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

- [Architecture](Docs/architecture.md): ownership boundaries and runtime flow.
- [MCP reference](Docs/mcp.md): tool schemas, discovery resources, session
  behavior, and runtime files.
- Run `scripts/publish-local-release.sh --help` for the maintainer-owned local
  release workflow.
