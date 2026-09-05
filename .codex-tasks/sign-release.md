# Remote signing contract

The next release phase prepares a Developer ID signed and notarized DMG as a GitHub Draft Release. It never publishes the release. Root owns workflow orchestration, GitHub release I/O, build versioning, README setup, integration and review. The signing worker owns only `scripts/sign_release.py` and `scripts/tests/test_sign_release.py`.

## Entry point and trust boundary

Use Python 3.10+ standard library and Apple command-line tools only. Do not import dmgbuild/ds_store, install dependencies, build code, run the app, or use Finder in the signing job. The caller downloads a single artifact by ID from the same trusted workflow run.

CLI: `python3 scripts/sign_release.py --input-dmg <path> --input-sha256 <64hex> --output-directory <path> --version <vMAJOR.MINOR.PATCH[-suffix]> --source-sha <40hex>`.

Before reading credentials, verify the source digest, safe version, exact source SHA equals GITHUB_SHA, GITHUB_REF is refs/heads/main, GITHUB_ACTIONS is true, and RUNNER_ENVIRONMENT is github-hosted. Native input validation must occur before credentials are imported. Only publish ready output after all signing, notarization, verification and cleanup succeed.

Secrets in the signing step only: DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD, NOTARY_API_PRIVATE_KEY (raw .p8 PEM). Configuration: APPLE_TEAM_ID, NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID. No login-keychain read or existing identity use. The temporary imported p12 must contain exactly one valid Developer ID Application identity for the configured team; choose its SHA-1 fingerprint. No arbitrary signing identity fallback. Temporary keychain password must be generated per run. Use import -x -T /usr/bin/codesign, never -A. Delete the keychain with security delete-keychain, and remove decoded p12/p8/password material on success and failure. Never log secrets or include secret-bearing argv in exceptions; use a single safe subprocess/error boundary. Do not read or export actual user credentials in development/tests.

## Native image and signing ownership

Input image is HFS+/GPT/UDZO. Convert to UDRW using hdiutil, expand the unmounted image to at least twice its original logical capacity (with explicit space for signature growth), then attach read-write at a private temp mount with no auto-open. codesign writes a full executable-sized .cstemp beside the executable; the current image has only ~2.6MB free and a ~60MB executable, so conversion alone is insufficient. Track successful attach's device to detach only this invocation's disk; do not enumerate/unmount unrelated volumes.

The verified current app contains exactly one Mach-O at Contents/MacOS/CodexReviewMonitor (arm64), identifier lynnpd.CodexReviewMonitor, and no nonempty entitlements. The source build will stamp CFBundleShortVersionString and CFBundleVersion with the numeric core of the version tag. Validate this product shape; reject new nested Mach-O or entitlement claims pending an explicit signing-order/profile design. Sign the app bundle once using --force --timestamp --options runtime --keychain <temp> --sign <verified fingerprint>, without --deep. Verify --deep --strict, identifier, TeamIdentifier, Developer ID authority, secure timestamp, and runtime flag. Preserve the .DS_Store and .background.png bytes and the U+200B /Applications symlink; snapshot only these existing immutable layout files, not a new mirror of app state.

Detach, convert to final UDZO with compression 9, sign the DMG with the same verified identity and identifier lynnpd.CodexReviewMonitor.dmg, verify signature/image integrity, notarize via API key using notarytool submit --wait --timeout 30m --output-format json. Require Accepted, retrieve the submission log, staple and validate the ticket, verify signature again and Gatekeeper assessment. A timeout may leave the server processing; record the submission response/id and stop without automatic resubmission. Never turn an Invalid/timeout/nonzero result into success.

## Successful output

Output directory must be new/empty; do not clobber old release products. Final ready files: `CodexReviewMonitor_<version without v>.dmg`, `release-info.json`, `SHA256SUMS`. Metadata: version, source_sha, repository (GITHUB_REPOSITORY), run_id, run_attempt, apple_team_id, signing_certificate_sha1, notary_submission_id, developer_id_signed true, notarized true. Compute hashes only after stapling; SHA256SUMS covers both DMG and release-info.json. When GITHUB_OUTPUT is set, emit `dmg-sha256=<hash>` and `dmg-filename=<name>` only after success. Diagnostic notary response/log may go to a caller-supplied `RELEASE_DIAGNOSTICS_DIRECTORY` outside upload output and must contain no credentials. Leave failed output absent, retain safe diagnostics.

## Validation / handoff

Read AGENTS/README and verify pwd/branch/status before edits. Test refusal before credential access, hash/version/ref mismatch, credential error redaction and cleanup, non-Accepted/timeout handling, and native convert/resize/mount/ad-hoc resign/finalize on a real tiny arm64 fixture. Production entry point never accepts ad-hoc fallback; native tests can exercise image helpers directly with a test-owned adhoc callback. Do not add fake/preview branches to production logic. No full app build/tests needed; root handles integration. Commit green checkpoints and final result to the worker task branch. Do not push or run codex-review. Escalate contract changes or three repeated failures before adding more branches. Report SHA, tests, and unverified Developer ID / Apple server behavior.
