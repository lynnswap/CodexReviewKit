# Releasing CodexReviewMonitor

This guide is for maintainers preparing signed release DMGs or validating the
release build. For app installation and client setup, see the
[README](../README.md#quick-start). Run the shell commands below from the
repository root.

## Prepare a Release

Maintainers can prepare a signed, notarized release entirely on GitHub Actions.
After the [one-time signing setup](#one-time-signing-setup), open
[Prepare Release](https://github.com/lynnswap/CodexReviewKit/actions/workflows/release.yml),
choose **Run workflow** on `main`, enter a new tag such as `v1.2.3`, and select
whether it is a prerelease.

The workflow runs the existing CI checks and headless DMG build at the same
commit. A separate macOS runner verifies that DMG, signs the app and disk image,
submits it to Apple's notary service, and staples the accepted ticket. This job
uses native Apple tools and the Python standard library; it does not install
build dependencies or execute the app. The runner's default Xcode is used.

The final job creates a Draft Release with the DMG, `release-info.json`, and
`SHA256SUMS`. It has GitHub write permission and no Apple credentials. The draft
targets the full tested commit SHA. Edit its generated release notes, review the
assets, then choose **Publish release** in GitHub. The workflow never publishes
the draft or creates the tag; GitHub creates the tag when you publish it.

The numeric part of the tag sets the app's marketing version: `v1.2.3-beta.1`
produces version `1.2.3`, with the full tag retained in the filename and metadata.
The workflow's run number sets the build version, so a new beta or release gets
a later build number even when the marketing version stays the same. Retrying
the same run keeps its build number.

An existing tag or release, including a draft, stops creation without replacing
notes or assets. After a partial failure, inspect the existing
draft before retrying. Notarization diagnostics include the submission ID;
a submission can continue at Apple after the workflow times out.

## One-time signing setup

Use **Settings → Environments → release-signing** for these values. Its branch
policy must allow only the `main` branch. If you also enable required reviewers,
leave **Prevent self-review** off when the maintainer who starts the workflow
must approve it.

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
`v0.0.0-validation`. The same build also runs for pull requests and pushes to
`main`.

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
