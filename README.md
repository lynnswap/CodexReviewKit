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

## Release Build Validation

Maintainers can build a validation DMG entirely on GitHub Actions. Open
[Release Build](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release-build.yml),
choose **Run workflow** on `main`, and enter a version label such as
`v0.0.0-validation`. The same build also runs for pull requests and pushes to
`main`.

The workflow builds the selected commit with Xcode 26.6, creates the DMG without
Finder or Apple credentials, and verifies the mounted app. Download the DMG,
`build-info.json`, and `SHA256SUMS` from the run's artifact. The metadata records
the source commit, version label, Xcode version, and workflow run. Artifacts are
retained for seven days. The version label names the artifact; it does not change
the app's bundle version.

These artifacts are for build and packaging validation. The app is ad-hoc signed;
the DMG is not Developer ID signed or notarized. The workflow creates no tag or
GitHub Release. Use the signed and notarized public release for installation.

To run the same packaging locally, create a Python 3.10 or newer virtual
environment and install the pinned DMG tools:

```bash
python3 -m venv .build/release-tools
source .build/release-tools/bin/activate
python3 -m pip install --require-hashes --only-binary=:all: \
  -r scripts/release-requirements.txt
scripts/build-release.sh --version v0.0.0-validation
scripts/package-release.sh --version v0.0.0-validation
```

The same Python environment is required by `scripts/publish-local-release.sh`
for the existing signed release process.

### Repository protection

The `main` ruleset requires a pull request, resolved review threads, and passing
GitHub Actions checks against the current base branch. Deletion and force pushes
are blocked. No additional human approval is required, allowing a solo maintainer
to merge a reviewed PR. CI runs for documentation-only changes too, so required
checks can finish on every PR.

The `release-signing` Environment is reserved for the later signing workflow and
allows only the `main` branch. The validation workflow does not use this
Environment or Apple secrets. Environment restrictions apply to the workflow's
ref; a future signing job must also bind its input artifact to the tested commit.

## More Detail

- [Architecture](Docs/architecture.md): ownership boundaries and runtime flow.
- [MCP reference](Docs/mcp.md): tool schemas, discovery resources, session
  behavior, and runtime files.
- Run `scripts/publish-local-release.sh --help` for the maintainer-owned local
  release workflow.
