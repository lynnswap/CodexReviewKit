# Release and build guide

For installation and MCP setup, see the [README](../README.md#quick-start).
Run the commands in this guide from the repository root.

## Publish a release

Complete the [signing setup](#one-time-signing-setup), then approve the version,
notes, and source commit. Save the approved notes in a UTF-8 file and run:

```bash
python3 scripts/prepare_release.py start \
  --repo lynnswap/CodexReviewKit \
  --version v1.2.3 \
  --notes-file /path/to/release-notes.md
```

Add `--prerelease` for a prerelease. The command creates a draft targeting the
current remote `main` commit, starts CI, and returns. It leaves tag creation to
publication. If workflow dispatch is uncertain, check Actions before retrying;
the draft remains available.

CI checks and builds the app, then waits for approval of the `release-signing`
Environment in GitHub. After approval, it signs with Developer ID, notarizes,
verifies and uploads the assets, and publishes the same draft. The draft's title
and notes are preserved. Publication continues without a local process watching
the run.

### Use an existing draft

Save the version, title, notes, and prerelease setting in GitHub, with `main` as
the target. Open
[Publish Release](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release.yml),
choose **Run workflow** on `main`, and enter the draft's tag.
[Creating or editing a draft does not trigger Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release),
so dispatch the workflow once. An API-created draft can instead target the full
workflow commit SHA; the workflow rejects a different commit.

### Assets and retries

The workflow pins the draft to its full source SHA before building. Checks pass
before signing, which runs separately with native Apple tools and a temporary
keychain. The signing job does not run the app. The publication job verifies
these three assets:

- The DMG
- `release-info.json`
- `SHA256SUMS`

Only those assets may be attached when the draft is published. Remove unintended
attachments before retrying. GitHub creates the tag at publication time.

A failure before publication leaves the draft unpublished. Rerun failed jobs to
reuse completed build and signing artifacts. An uploaded asset with matching
bytes is kept; different bytes under the same name stop publication. If
publication succeeded but confirmation failed, rerunning the publication job
checks the existing assets and tag without changing the release.

Rerunning the whole workflow can produce different artifacts. Inspect existing
draft assets before removing them and retrying. While a run is active, keep its
tag, source commit, and prerelease setting fixed. You can edit the title and
notes. Apple may continue notarization after a workflow timeout; use the
submission ID in the diagnostics to identify it.

The tag's numeric part sets the marketing version: `v1.2.3-beta.1` becomes
`1.2.3`. Filenames and metadata retain the full tag. The workflow run number is
the build version, and a retry of the same run keeps that number.

## One-time signing setup

In **Settings → Environments → release-signing**, allow only `main` and require
a reviewer. Leave **Prevent self-review** off if the maintainer starting the run
will also approve signing. CI publishes after approval and successful checks.

| Environment secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded, password-protected `.p12` with the intended Developer ID Application certificate and private key |
| `DEVELOPER_ID_P12_PASSWORD` | Export password for the `.p12` |
| `NOTARY_API_PRIVATE_KEY` | Full contents of the App Store Connect Team API key's `.p8` file |

| Environment variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Team ID matching the signing certificate |
| `NOTARY_API_KEY_ID` | App Store Connect API key ID |
| `NOTARY_API_ISSUER_ID` | Team API key issuer UUID |

Export one valid **Developer ID Application** identity, including its private
key, to the password-protected `.p12`, and keep a secure backup. An
`Apple Development` certificate cannot sign this distribution. For
notarization, create a dedicated **Team API key** with the **Developer** role.
That role also permits operations beyond notarization and this app. See
[Apple's Developer ID guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [API key management](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

With GitHub CLI authenticated, upload secrets from local files:

```bash
base64 < /secure/path/DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 \
  --repo lynnswap/CodexReviewKit --env release-signing
gh secret set DEVELOPER_ID_P12_PASSWORD \
  --repo lynnswap/CodexReviewKit --env release-signing
gh secret set NOTARY_API_PRIVATE_KEY \
  --repo lynnswap/CodexReviewKit --env release-signing < /secure/path/AuthKey.p8
```

The password command prompts for its value. Add the three variables in the
Environment's Variables section. The signing step checks the imported
certificate's team and type, then removes the temporary keychain and decoded
key files when it finishes. Keep credentials out of the repository and build
artifacts; update or revoke them through Apple and GitHub.

## Release build validation

Open
[Release Build](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release-build.yml),
choose **Run workflow** on `main`, and enter a label such as
`v0.0.0-validation`. The build also runs on pushes to `main`.

The workflow uses the runner's default Xcode, packages the selected commit
without Finder or Apple credentials, and verifies the mounted app. Download the
DMG, `build-info.json`, and `SHA256SUMS` from its artifact, retained for seven
days. The metadata records the commit, version label, Xcode version, and run.
The label's numeric part sets the marketing version; the run number sets the
build version.

Validation artifacts use an ad-hoc app signature. The DMG has no Developer ID
signature or notarization, and the workflow creates no tag or GitHub Release.
Use a signed public release for installation.

For the same packaging locally, prepare Python 3.10 or newer and the pinned
DMG tools:

```bash
python3 -m venv .build/release-tools
source .build/release-tools/bin/activate
python3 -m pip install --require-hashes --only-binary=:all: \
  -r scripts/release-requirements.txt
scripts/build-release.sh --version v0.0.0-validation
scripts/package-release.sh --version v0.0.0-validation
```

Local validation uses build number `1`. Pass `--build-number` to the build
script for another positive integer.

## Local builds

For a local app build, use an Apple silicon Mac with Xcode 26.4 or newer and
Python 3.10 or newer:

```bash
python3 scripts/build_review_monitor.py
```

The script creates `dist/CodexReviewMonitor_yymmdd_hhmm.dmg`, named with the local
build-start time. It applies an ad-hoc hardened-runtime signature and verifies
the DMG contents. Caches stay in `.build`; the first run prepares the pinned
DMG tools in `.build/release-tools` and may download locked package dependencies.

ReviewMonitor can stay open during the build. When reviews finish, quit the
app, open the DMG, drag the app to Applications, choose **Replace**, and relaunch.
You can replace the app without deleting it first. The script leaves installed
apps alone. Builds started in the same minute replace the same DMG only after
the new image passes validation; older filenames are kept.

The ad-hoc signature is for local use. To select an approved local identity,
pass it explicitly:

```bash
python3 scripts/build_review_monitor.py \
  --signing-identity 'Apple Development: Developer Name (TEAMID)'
```

The script uses that identity or fails; it never falls back to another one.
Local signing does not notarize the app or make it suitable for redistribution.
Device-management policy can still prohibit it. The script leaves Gatekeeper
and quarantine metadata in place. The app requires macOS 26 or newer.

## Repository protection

The `main` ruleset requires a PR, resolved review threads, and passing GitHub
Actions checks against the current base branch. It blocks deletion and force
pushes. A solo maintainer can merge a reviewed PR without another human approval.
CI also runs for documentation changes so required checks can finish on every PR.

Only `main` can use `release-signing`. Build validation uses neither that
Environment nor Apple secrets. Signing checks that its input artifact ID and
file digest belong to the build in the same workflow run.
