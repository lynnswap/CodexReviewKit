# Release and build guide

Run these commands from the repository root.

## Publish a release

Complete the [signing setup](#one-time-signing-setup) and approve the version,
release notes, and current `main` commit. Pass the saved UTF-8 notes to the
release script.

```bash
python3 scripts/prepare_release.py start \
  --repo lynnswap/CodexReviewKit \
  --version v1.2.3 \
  --notes-file /path/to/release-notes.md
```

Add `--prerelease` for a prerelease. The command tags the current remote
`main` commit, creates a draft, and starts CI. If dispatch is uncertain, check
Actions before retrying. The command can reuse a matching tag and draft.

Once checks pass, approve the `release-signing` deployment in GitHub. The
workflow signs the app and DMG, submits the DMG for notarization, verifies
the assets, and publishes the draft.

### Use an existing draft

Save the draft in GitHub with its version, title, notes, prerelease setting,
and `main` as the target. In the
[Publish Release workflow](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release.yml),
choose **Run workflow** on `main` and enter the draft's tag. An API-created
draft may also target the workflow's full commit SHA.

### Assets and retries

Keep the tag, source commit, and prerelease setting fixed during a run. You
can edit the draft's title and notes. The tag's numeric part sets the marketing
version (`v1.2.3-beta.1` becomes `1.2.3`). The run number sets the build version.

- If a job fails, rerun the failed jobs to reuse the tested artifacts. A full
  rebuild can produce different bytes. After a notarization timeout, use the
  submission ID in the diagnostics to check its status.
- The draft may contain only the DMG, `release-info.json`, and `SHA256SUMS`.
  Publication keeps matching assets and stops on conflicting ones. Inspect
  unexpected attachments before removing them and retrying.
- If publication succeeded but confirmation failed, rerun the publication job
  to verify the published assets and tag.

## One-time signing setup

In **Settings → Environments → release-signing**, allow only `main` and require
a reviewer. Leave **Prevent self-review** off if the maintainer starting the run
will also approve signing.

| Environment secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded, password-protected `.p12` containing one Developer ID Application certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Export password for the `.p12` |
| `NOTARY_API_PRIVATE_KEY` | Full contents of the App Store Connect Team API key's `.p8` file |

| Environment variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Team ID matching the signing certificate |
| `NOTARY_API_KEY_ID` | App Store Connect API key ID |
| `NOTARY_API_ISSUER_ID` | Team API key issuer UUID |

Use a dedicated Team API key with the **Developer** role for notarization.
This role also grants access beyond notarization. See Apple's guides to
[Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

Upload the secrets from local files with GitHub CLI. The password command
prompts for the export password.

```bash
base64 < /secure/path/DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 \
  --repo lynnswap/CodexReviewKit --env release-signing
gh secret set DEVELOPER_ID_P12_PASSWORD \
  --repo lynnswap/CodexReviewKit --env release-signing
gh secret set NOTARY_API_PRIVATE_KEY \
  --repo lynnswap/CodexReviewKit --env release-signing < /secure/path/AuthKey.p8
```

## Release build validation

The [Release Build workflow](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release-build.yml)
runs on pushes to `main`. To start it manually, choose **Run workflow** on
`main` and enter a label such as `v0.0.0-validation`. The artifact contains
an unsigned validation DMG with an ad-hoc-signed app, `build-info.json`, and
`SHA256SUMS` for seven days. For installation, download the notarized DMG from
the [latest release](https://github.com/lynnswap/CodexReviewKit/releases/latest).

To validate the same packaging locally, use Python 3.10 or newer.

```bash
python3 -m venv .build/release-tools
source .build/release-tools/bin/activate
python3 -m pip install --require-hashes --only-binary=:all: \
  -r scripts/release-requirements.txt
scripts/build-release.sh --version v0.0.0-validation
scripts/package-release.sh --version v0.0.0-validation
```

Local validation uses build number `1`. Pass `--build-number` to the build
script to select another positive integer.

## Local builds

The [local build command](../README.md#build-from-source) requires an Apple
silicon Mac with Xcode 26.4 or newer and Python 3.10 or newer. It uses ad-hoc
signing by default. To select a local identity, pass `--signing-identity`.

```bash
python3 scripts/build_review_monitor.py \
  --signing-identity 'Apple Development: Developer Name (TEAMID)'
```

Use the release workflow for a notarized DMG.
