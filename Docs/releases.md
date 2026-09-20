# Releasing CodexReviewMonitor

This guide is for maintainers preparing signed release DMGs or validating the
release build. For app installation and client setup, see the
[README](../README.md#quick-start). Run the shell commands below from the
repository root.

## Publish a Release

After the [one-time signing setup](#one-time-signing-setup), approve the version,
release notes, and source commit before starting publication. CI runs checks and
the build, then waits for your approval of the `release-signing` Environment.
After you approve in GitHub, CI performs Developer ID signing, notarization,
asset upload, and publication automatically.
A successful run publishes the existing draft without changing its title or notes.
No local process or LLM needs to watch the run.

To create the draft and start CI in one operation, save the approved notes in a
UTF-8 file and run:

```bash
python3 scripts/prepare_release.py start \
  --repo lynnswap/CodexReviewKit \
  --version v1.2.3 \
  --notes-file /path/to/release-notes.md
```

Add `--prerelease` for a prerelease. The command targets the current remote `main`
commit, creates a draft with the supplied notes, dispatches the workflow, and
returns immediately. It does not create a tag or wait for CI. If dispatch cannot
be confirmed, the draft remains available; check Actions before retrying the
workflow to avoid starting it twice.

To use a draft already prepared in GitHub, save its version, title, notes, and
prerelease setting with `main` as the target. Then open
[Publish Release](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release.yml),
choose **Run workflow** on `main`, and enter the draft's tag. This requests
publication after CI succeeds and you approve signing.
[Draft creation and editing do not trigger Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release),
so this one dispatch is necessary. An API-created draft can target the full
workflow commit SHA instead of `main`; a different commit is not silently substituted.

The workflow pins the draft to its full source SHA before building. All CI checks
must pass before signing. Signing runs separately from the build, uses native
Apple tools and an ephemeral keychain, and does not execute the app. The final
job verifies and uploads the DMG, `release-info.json`, and `SHA256SUMS`, then
publishes that same draft. GitHub creates the tag at publication time.

Failures before publication leave the release as a draft. Rerun failed jobs to
reuse successfully built and signed artifacts. Matching uploads are retained;
different bytes under an existing asset name stop publication instead of being
overwritten. If publication succeeded but its confirmation failed, rerunning the
publish job confirms the same assets and tag without changing the public release.
If rerunning the entire workflow creates different artifacts, inspect
the draft's existing assets before removing them and retrying. Keep the tag,
target commit, and prerelease setting unchanged while a run is active; title and
release-note edits are preserved. Notarization can continue at Apple after a
workflow timeout; diagnostics include its submission ID.

The numeric part of the tag sets the app's marketing version: `v1.2.3-beta.1`
produces version `1.2.3`, with the full tag retained in the filename and metadata.
The workflow run number sets the build version. Retrying the same run keeps its
build number.

## One-time signing setup

Use **Settings → Environments → release-signing** for these values. Its branch
policy must allow only the `main` branch, with a required reviewer for signing.
Leave **Prevent self-review** off when the maintainer starting the workflow also
approves it. The maintainer approves this Environment in GitHub; CI publishes
automatically after the approved signing job and all checks succeed.

| Environment secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 encoding of a password-protected `.p12` containing only the intended Developer ID Application certificate and private key |
| `DEVELOPER_ID_P12_PASSWORD` | The `.p12` export password |
| `NOTARY_API_PRIVATE_KEY` | The full contents of the App Store Connect Team API key's `.p8` file |

| Environment variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | The Apple Developer Team ID matching the signing certificate |
| `NOTARY_API_KEY_ID` | The App Store Connect API key ID |
| `NOTARY_API_ISSUER_ID` | The issuer UUID for the Team API key |

Export the intended **Developer ID Application** signing identity, including its
private key, as a password-protected `.p12`. An `Apple Development` certificate
does not work for this distribution channel. Keep a secure backup of the signing
identity. For notarization, create a dedicated **Team API key** with the
**Developer** role; this role permits notarization but is not limited to it or to
this app. See [Apple's Developer ID guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [API key management](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

With an authenticated GitHub CLI, secrets can be uploaded from local files
without putting their contents in command arguments:

```bash
base64 < /secure/path/DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 \
  --repo lynnswap/CodexReviewKit --env release-signing
gh secret set DEVELOPER_ID_P12_PASSWORD \
  --repo lynnswap/CodexReviewKit --env release-signing
gh secret set NOTARY_API_PRIVATE_KEY \
  --repo lynnswap/CodexReviewKit --env release-signing < /secure/path/AuthKey.p8
```

The password command prompts for its value. Enter the three non-secret variables
in the Environment's Variables section. The signing step imports the identity
into a temporary keychain, verifies its team and certificate type, and removes
the keychain and decoded key files when it finishes. The `.p12` must contain only
one valid signing identity. Keep credentials out of repository files and build
artifacts; update or revoke them through Apple and GitHub when needed.

## Release Build Validation

Maintainers can build a validation DMG entirely on GitHub Actions. Open
[Release Build](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release-build.yml),
choose **Run workflow** on `main`, and enter a version label such as
`v0.0.0-validation`. The same build also runs for pushes to `main`.

The workflow builds the selected commit with the runner's default Xcode, creates
the DMG without Finder or Apple credentials, and verifies the mounted app.
Download the DMG, `build-info.json`, and `SHA256SUMS` from the run's artifact. The metadata records
the source commit, version label, Xcode version, and workflow run. Artifacts are
retained for seven days. The numeric part of the version label sets the app's
marketing version; the workflow run number sets its build version.

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

Local validation defaults to build number `1`; pass `--build-number` to the build
script to use another positive integer.

## Repository protection

The `main` ruleset requires a pull request, resolved review threads, and passing
GitHub Actions checks against the current base branch. Deletion and force pushes
are blocked. No additional human approval is required, allowing a solo maintainer
to merge a reviewed PR. CI runs for documentation-only changes too, so required
checks can finish on every PR.

The `release-signing` Environment allows only the `main` branch. The validation
workflow does not use this Environment or Apple secrets. The signing workflow
also binds its input artifact ID and file digest to the build in the same run.
