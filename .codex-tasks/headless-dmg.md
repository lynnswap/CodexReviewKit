# Headless DMG implementation contract

The authorized first phase builds an ad-hoc signed macOS app and DMG without Apple credentials, ready for download as a GitHub Actions artifact. Existing signed local releases must remain usable until the later signing/notarization migration. Do not create or publish a release, tag, or secret.

## Ownership and write set

The packaging worker owns `scripts/package-release.sh`, a `scripts/dmg-settings.py` settings file if needed, `scripts/release-requirements.txt`, and `scripts/tests/test_package_release.py`. Root owns workflows, build script, README, repository protection settings, integration, and PR. Do not change other files. This temporary task contract will be deleted before delivery.

The existing package script owns input validation, app checks, output naming, DMG packaging, optional signing, and optional notarization. Adopt dmgbuild for headless filesystem/image and Finder metadata generation, deleting the old Finder AppleScript path and redundant mount/image code. Keep the current command-line flags and signed/notarized behavior. Use installed `python3` from a caller-managed virtual environment; dependency installation is an explicit prerequisite, never implicit in a signing script. Keep Python >=3.10 compatibility.

## Behavior

- Preserve the existing white/blue 480x540 background and app/Applications-link positions (240,122)/(240,387), icon size 128, invisible link name U+200B and /Applications target. Use dmgbuild settings; do not implement a custom DS_Store serializer or check in volume-specific metadata. Window content size 480x540 is the contract; exact desktop position is not.
- Package arm64 CodexReviewMonitor.app to CodexReviewMonitor_<version without v>.dmg with UDZO/HFS+ and compression 9. Preserve signature before packaging and ensure source app is not mutated.
- Preserve explicit Developer ID signing/notary profile input paths. Without them the artifact remains for validation only, with a clear warning; never claim it is notarized or publicly distributable.
- Invalid/missing source app or signature, malformed/missing required arguments, wrong architecture, dependency missing, creation failure, or output validation failure must fail the command. Avoid fallback, silent errors, unchecked subprocess results, and broad recovery.
- Validate the actual produced image using hdiutil verify and a private read-only mount. Check the mounted app is complete and its signature valid, architecture correct, Applications link correct, and layout metadata/background present. Do not detach unrelated existing user mounts. Always clean up only mounts/temp paths owned by this invocation. Validate before optional signing/notarization. App signature validation of mounted copy must not execute the app.
- Use explicit hashes and wheel-only installation for dmgbuild==1.6.7, ds-store==1.3.3, mac-alias==2.2.3. Root has primary-source verified hashes; confirm before writing if not provided in prompt.

## Validation and handoff

Run bash syntax/shellcheck as applicable and focused tests that exercise headless packaging with a real minimal arm64 signed app fixture and actual hdiutil/dmgbuild (no Finder). Test missing/invalid app and source preservation/failure cleanup where meaningful. No full product build or Swift package/app tests; root will run those. Mock-based tests should exercise error propagation and contracts, not mirror implementation.

Before edits verify pwd, git status --short, and branch. Work only on the assigned worker worktree and task branch. Commit a green result to that branch; no push and no local or remote review invocation. Report commit SHA, changed files, commands/results, any notary/signing paths that remain untested. Escalate if preserving the signed path requires scope outside the write set, different dependencies, or a behavior change beyond this contract.
