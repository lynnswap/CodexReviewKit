# Recovery Wave 0/1 task brief (2026-08-20)

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Approved design checkpoint | `b47d83c117e11bdf244d4dba2a6ab07ef92b3ce6` |
| Design contract | `Docs/recovery-design-2026-08-20.md` |
| Recovery ledger | `Docs/review-stability-recovery-2026-08-20.md` |
| Phase | Approved Phase 3 migration, Wave 0/1 |

This file is the committed worker contract for the first implementation slices.
Workers may implement only their assigned charter. A required change to public
API, the approved owner map, persistence schema, migration policy, or another
worker's write set is an escalation to the integration owner, not a local design
decision.

## Shared invariants

- The recovery remains based on published v0.6.2. Do not copy the unreleased
  generic Codex chat/DataKit presentation architecture.
- `~/.codex_review` and the existing
  `codexReview.runtimePreferences` value are read-only legacy inputs. Wave 0/1
  must not write them.
- Product behavior remains owned by `CodexReviewJob`/`CodexReviewStore`; no
  second cache, wrapper state, or app-server thread-list source of truth.
- Fail fast with typed errors. Do not hide a failure with a guard, fallback,
  retry, sleep, or guessed default.
- Existing public v0.6.2 source surface stays compatible. New public API is not
  authorized by these slices unless this brief names it explicitly.
- Do not change the recovery design or ledger from worker branches.
- Do not edit `Package.resolved` unless the assigned slice intentionally changes
  dependency resolution. Diagnostic-only churn must be restored before commit.
- Each worker commits green checkpoints to its own branch, runs its assigned
  validation, runs Codex review, and reports a clean worktree. No worker pushes,
  creates a PR, tags, or edits the integration branch.

## Worker A — RecoveryV1 environment isolation (Wave 0)

### Outcome

Every production, preview, test, and development launch resolves its writable
runtime paths from one RecoveryV1 environment owner. A default recovery build
cannot write the current-main home or preference key, and app-server/MCP
admission does not start until the recovery directories are prepared.

### Owner and allowed write set

The composition/runtime boundary in `CodexReviewHost` owns path resolution and
preparation. The ReviewMonitor app consumes it; domain review/store code does
not inspect filesystem paths.

Allowed files/responsibilities:

- `Sources/CodexReviewHost/CodexReviewRuntimePreferences.swift`
- `Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift`
- one new RecoveryV1 environment file under `Sources/CodexReviewHost/`
- `Tools/ReviewMonitor/CodexReviewMonitor/CodexReviewMonitorApp.swift`
- corresponding `CodexReviewHostTests` and ReviewMonitor composition/CI tests

Do not modify ReviewUI, MCP schemas, persistence implementation, authentication
flows, executable discovery, or legacy import.

### Required contract

- One package-owned environment value resolves these URLs below ReviewMonitor
  Application Support: `RecoveryV1/CodexHome`,
  `RecoveryV1/LoginStaging`, `RecoveryV1/SavedAccounts`, and
  `RecoveryV1/review-history.sqlite`.
- The default preference key is
  `codexReview.recoveryV1.runtimePreferences`; the existing key is never read as
  an automatic fallback and never overwritten.
- The existing public `CodexReviewStore.makeLiveStore(...)` signature remains
  exact. Its default path resolves to RecoveryV1. An explicitly configured safe
  `codexHomePath` remains supported; the known legacy default path must not be
  silently selected.
- Tests and probes inject an isolated base directory, preference suite, and MCP
  port through owner seams. They never touch the user's Application Support,
  UserDefaults domain, or port 9417.
- Directory preparation is awaited before MCP bind or app-server creation,
  creates owner-only directories, and surfaces a typed start failure. It does
  not create/open the history database yet.
- Preview/XCTest launch behavior remains non-live unless an existing explicit
  integration-test override requests a server.

If preserving the exact public factory requires a new public declaration or if
the current settings UI makes the legacy home reachable in a way this contract
cannot reject without an API change, stop and escalate with options.

### Budget and validation

- Budget: 4 hours; at most 4 production files and 4 test files.
- Targeted host tests for default path, explicit path, legacy isolation,
  directory permissions/preparation failure, preference-key separation, and
  test/probe isolation.
- ReviewMonitor app composition tests for live vs preview/XCTest admission.
- `swift test --build-system swiftbuild --no-parallel --filter CodexReviewHostTests`
- Relevant ReviewMonitor CI tests, then the full package suite if the targeted
  gate passes.

## Worker B — Native log viewport stability (#103, Wave 1)

### Outcome

The confirmed v0.6.2 multiline-stream/live-resize regression is fixed at the
native log scroll/layout owner. Auto-follow keeps the viewport bottom filled
after TextKit 2 reflow, while explicit user scroll-away remains stable.

### Owner and allowed write set

- `Sources/ReviewUI/Detail/ReviewMonitorLogScrollView.swift`
- only directly required neighboring `ReviewUI/Detail` owner files
- `Tests/ReviewUITests/ReviewUIShellTests.swift` and a directly related ReviewUI
  test helper if required

Do not modify sidebar layout/accessories, product/store state, runtime paths,
MCP, persistence, or loosen the existing failure assertion. Do not add a delay,
extra queue turn, repeated scroll retry, or private API.

### Required contract

- Reproduce
  `detailLogKeepsBottomFilledForMultilineStreamDuringLiveWindowResize` before
  editing.
- Determine the broken layout/scroll invariant and its owner. Preserve native
  AppKit/TextKit lifecycle rather than forcing test-only layout branches.
- Semantic render/layout completion is the synchronization boundary.
- Pin bottom after multiline reflow only when auto-follow was active before the
  size change. User scroll-away must not be overridden.
- The fix must remain valid outside live-resize and must not regress find bar,
  overlay scroller, command-output panels, or compact width.
- Read and follow `apple-sdk-usage` before editing. Verify any AppKit/TextKit API
  behavior against the installed SDK or Apple documentation.

If the root owner is outside the allowed ReviewUI files or the fix needs a new
public/test-only production branch, stop and escalate.

### Budget and validation

- Budget: 3 hours; at most 2 production files and 2 test files.
- Focused failing test first, plus adjacent resize/reflow/scroll-away tests.
- `swift test --build-system swiftbuild --no-parallel --filter ReviewUIShellTests`
- Full package suite after the focused suite passes.

## Worker C — Published compatibility gates (Wave 1)

### Outcome

Before later waves add terminal/history API, the exact v0.6.2 public products
and MCP tools are captured by executable gates: a separate consumer package, a
public API baseline check, and a canonical MCP tool-schema golden test.

### Owner and allowed write set

- a new `Fixtures/CodexReviewKitProductConsumer/` package
- new compatibility scripts and tracked baselines under `scripts/` and a
  purpose-named baseline directory
- `Tests/CodexReviewMCPServerTests/` golden fixture/test support
- root `Package.swift` only if a test resource declaration is strictly required

Do not modify production public declarations, ReviewUI/runtime behavior,
workflows, dependencies, or generated package lockfiles.

### Required contract

- The consumer is a separate Swift package using a local package dependency and
  imports all four published products without `@testable` or package access. It
  builds and runs a small v0.6.2 consumer story.
- A deterministic script captures/checks the public surface of `CodexReview`,
  `CodexReviewHost`, `ReviewUI`, and `TextTransitions` using
  `swift-api-digester` where supported. Toolchain/environment failures are loud;
  the script does not silently fall back to grep-only success.
- The baseline is generated from this approved v0.6.2 recovery base and is
  tracked with toolchain/revision metadata. Future additive accepted changes can
  update it only with an explicit design entry.
- MCP `tools/list` is canonicalized and compared to a tracked golden containing
  exactly `review_start`, `review_await`, `review_read`, `review_list`, and
  `review_cancel` with the published v0.6.2 field/alias schema. Dictionary key
  order must not make the test flaky.
- One documented command runs all three gates and exits nonzero on drift.

If `swift-api-digester` cannot produce a stable baseline for the SwiftPM build,
stop after committing a reproducible probe/failure only if instructed by the
integration owner; otherwise escalate with the exact command/output and a
recommended alternative. Do not invent a passing weak substitute.

### Budget and validation

- Budget: 5 hours; at most 10 new/changed files.
- Build/run the separate consumer package.
- Run the public API baseline checker twice from a clean state.
- Run the focused MCP server schema test twice.
- Run the one aggregate compatibility command and relevant package tests.

## Integration order

1. Worker B (#103) may integrate first because it makes the v0.6.2 baseline
   green and touches only ReviewUI.
2. Worker A integrates next and establishes the safe execution environment.
3. Worker C integrates last, rebases/regenerates only if the first two slices
   make an accepted public/API change (none is expected).
4. The integration owner runs full package and app tests, then branch-wide Codex
   review before starting Wave 2.
