# Retired Recovery Wave 0 and independent baseline gates (2026-08-20)

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Historical design checkpoint | `b47d83c117e11bdf244d4dba2a6ab07ef92b3ce6` |
| Design contract | `Docs/recovery-design-2026-08-20.md` |
| Recovery ledger | `Docs/review-stability-recovery-2026-08-20.md` |
| Wave 0 status | **Rejected and retired; `c83e499` is evidence only and must not merge** |
| Baseline-gate status | Gate V merged in PR #114 (`f4c9bb0`); Gate C pending independent publication |

This file preserves the rejected Wave 0 evidence and records the independently
delivered Gate V plus still-pending Gate C from the restored v0.6.2 tree.
It is not authorization to merge any RecoveryV1 implementation from
`codex/recovery-wave-0-1-pr`. A required change to public API, the owner map,
persistence schema, migration policy, or another gate's write set is an
escalation to the integration owner, not a local design decision.

## Shared invariants

- The recovery remains based on published v0.6.2. Do not copy the unreleased
  generic Codex chat/DataKit presentation architecture.
- `~/.codex_review` and the existing
  `codexReview.runtimePreferences` value are read-only legacy inputs. Neither
  baseline gate may inspect or write them.
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

## Retired Worker A — path-owned RecoveryV1 environment (former Wave 0)

### Disposition

The implementation ending at `c83e49960c303682ea4b4be77a8cfe0f7ff59151`
is rejected. It remains history evidence only and must not be merged,
cherry-picked, repaired in place, or used as a prerequisite SHA. The same
path-ownership invariant recurred over four implementation rounds:

1. `864b16a` introduced URL/path-owned RecoveryV1 preparation.
2. `3b2def2` added missing staging/runtime-directory handling.
3. `d3f3e20` added further path overlap, ownership, mode, symlink, and cleanup
   checks.
4. `c83e499` added another directory-chain, cancellation rollback, staging
   cleanup, and test-isolation correction.

This crosses the program stop condition. More URL canonicalization, `lstat`
checks, path-prefix guards, or Environment-owned cleanup would be a fifth patch
to an ownerless contract. Issue #113 replaces the design with descriptor-backed
authority after reviewed Wave 3 and before any Wave 4 GRDB open.

### Rejected owner and write set

`CodexReviewRecoveryEnvironment` must not remain the mutation/removal owner.
The following historical write set identifies code to retire or replace at the
#113 gate; it is not an allowed worker write set here:

- `Sources/CodexReviewHost/CodexReviewRuntimePreferences.swift`
- `Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift`
- `Sources/CodexReviewHost/CodexReviewRecoveryEnvironment.swift`
- `Tools/ReviewMonitor/CodexReviewMonitor/CodexReviewMonitorApp.swift`
- corresponding `CodexReviewHostTests` and ReviewMonitor composition/CI tests

Do not reuse the former 4-hour / 4-production + 4-test budget for #113. The
descriptor core has a separate file/time budget in the canonical design and
ledger. `RecoveryEnvironmentPlan` may describe configuration; it does not own
login staging allocation, a cleanup manifest, recursive removal, RegistryV2,
or authentication debt.

## Gate V — Native log viewport stability (#103)

Status: merged to restored `main` by PR #114 at `f4c9bb02b721`; reviewed
source commit `55f68c032134` and CI Package Tests are green.

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

## Gate C — Published compatibility gates

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

## Independent delivery and successor gates

- Gate V and Gate C branch independently from restored `main`/v0.6.2. Neither
  branch contains the rejected Wave 0 implementation, and neither branch is the
  review/validation substitute for the other.
- Gate V is the independently published behavior fix: PR #114 merged reviewed
  source `55f68c0` as `f4c9bb0`. Its review/CI does not validate Gate C.
- Gate C is a contract-test change and must be landed and reviewed before the
  current-event wave introduces accepted public terminal additions. It does not
  depend on Gate V unless its exact test fixture proves a real dependency.
- Historical `03bf36e` remains local evidence superseded by Gate V's actual
  reviewed landing. `3801200` remains compatibility evidence only; Gate C's
  current independent candidate is `codex/add-v062-compatibility-gates-pr@94de08f`
  and still requires its own publication/review record.
- The current-event contract then lands and is reviewed independently. Only
  that reviewed HEAD may become the Wave 3 base.
- Issue #113 starts only after reviewed Wave 3C. It is the replacement for
  former Worker A, not another part of either baseline gate.
