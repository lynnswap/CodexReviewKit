# ReviewMonitor stability recovery ledger (2026-08-20)

Status: In progress

Tracking issue: [#96](https://github.com/lynnswap/CodexReviewKit/issues/96)

Current-main baseline: `26c8f7b49e4afb356698d3c49e5107e96477b2ca`

Known-good candidate: `v0.6.2` (`c8c01d669673d41864db666507f1580155e8f89e`, release commit `82bddbcb1310a091eff742b36ab90781a4cbee5a`)

Audit branch: `codex/restore-review-stability`

Recovery branch: `codex/v0-6-2-recovery`

This is a resumable working ledger for the recovery. The proposed Phase 2
contract is [recovery-design-2026-08-20.md](recovery-design-2026-08-20.md).
Keep evidence, decisions, checkpoints, and remaining work here until the
recovery is complete; then either retain the durable architecture contract or
remove this transient ledger.

## Reported failures

1. A terminal review message can be rendered as the raw structured JSON result.
2. A completed sidebar row shows the age since completion instead of review duration.
3. Review/log rows can disappear and return roughly one minute later.
4. Log presentation can fail or crash.
5. Review execution is generally unstable compared with v0.6.2.

## Scope and compatibility contract

- The current architecture is not a compatibility requirement.
- A clean branch from v0.6.2 is the selected recovery basis.
- Preserve the externally used MCP tool names and user-visible review behavior unless evidence requires a deliberate contract change.
- Reintroduce post-v0.6.2 functionality only when a concrete consumer need is confirmed and tracked by its own issue.
- API key authentication/login and Codex executable discovery are confirmed feature candidates.
- Do not preserve repo-internal compatibility shims or parallel state paths solely to ease migration.
- Keep current `main` and its persisted user data recoverable while testing the candidate branch.
- The bottom status accessory overlap is explicitly out of scope at the user's request.

## Tracked issues

- #97: API key authentication.
- #98: Codex executable discovery.
- #99: internal reviewer child payload leakage.
- #100: review duration and restart/replay semantics.
- #102: durable local review/log history.
- #103: live log viewport stability.
- #104: current review terminal contract.
- #105: current notification/output normalization.
- #106: cancellation terminal barrier.
- #107: current ChatGPT login lifecycle.
- #108: recoverable local-state cutover.
- #109: current-client MCP compatibility proof.
- #110: anchor-based sidebar reorder and durable manual order.
- #111: bounded history paging and explicit terminal deletion.
- #101: closed as not planned by user decision.

## Recovery decision and remaining design gate

The selected architecture direction is:

1. **Restore from v0.6.2:** retain the product-owned review/store/UI flow and reimplement required features.
2. **Do not repair the current generic-chat architecture:** it admits internal reviewer children as product rows and changes row semantics when the process-local run owner disappears.

The proposed Phase 2 gate now includes:

- [x] current and desired owner maps for review identity, terminal result,
  persistence/replay, observation, selection, duration, and rendering;
- [x] a required-feature inventory with one issue per independent contract;
- [x] persisted-data and external MCP compatibility policy;
- [x] deletion/cutover list;
- [x] characterization and runtime test plan;
- [x] finding-to-design mapping;
- [x] explicit user approval of the concrete design gate before product edits.

## Evidence checklist

- [x] Classify the `v0.6.2...main` history by owner and identify regression commits where possible.
- [x] Run the repository package tests at current `main` and v0.6.2.
- [x] Run the ReviewMonitor app tests at current `main` and v0.6.2.
- [x] Inspect available crash/error evidence without exposing credentials or review contents.
- [x] Reproduce live review completion and terminal presentation.
- [ ] Reproduce selection/rebind, refresh, restart, and persisted replay.
- [x] Trace the approximately one-minute disappearance/recovery boundary.
- [x] Verify completed-row duration semantics.
- [x] Inventory post-v0.6.2 required features and create child issues.
- [ ] Complete Codex self-review after integration validation.

## Checkpoints

| Time | State | Evidence / next action |
|---|---|---|
| 2026-08-20 | Audit started | Current baseline clean at `26c8f7b`; screenshot confirms terminal JSON and duration symptoms. |
| 2026-08-20 | Parent issue created | Issue #96 owns the recovery program and acceptance criteria. |
| 2026-08-20 | Isolated recovery branch created | `codex/v0-6-2-recovery` starts at `v0.6.2`; validate it before changing architecture. |
| 2026-08-20 | Regression owners confirmed | #99 tracks internal reviewer-child leakage; #100 tracks duration and restart/replay semantics. |
| 2026-08-20 | Required features started | #97 tracks API key authentication and #98 tracks executable discovery. |
| 2026-08-20 | Baseline tests | Both app schemes pass. Current package tests deterministically crash in the API-key prompt UI test; v0.6.2 package UI tests reproducibly fail the multiline stream/resize bottom-pinning test (#103). |
| 2026-08-20 | Recovery direction selected | Use v0.6.2 as the base; do not preserve the current generic-chat presentation architecture. |
| 2026-08-20 | Scope reduced | #101 closed as not planned; bottom accessory overlap is not part of this recovery. |
| 2026-08-20 | Live proof | Run `8C62A88B-...` confirmed one product row plus one reviewer-child row, initial list omission, human outer output, child JSON, and terminal refresh churn. |
| 2026-08-20 | Durable owner selected | #102 and the design contract make local SQLite review history the sidebar/detail/MCP source of truth. |
| 2026-08-20 | Feature inventory complete | #104–#109 isolate current terminal, notification, cancellation, login, cutover, and MCP contracts; unreleased DataKit/SDK architecture is excluded. |
| 2026-08-20 | Design checkpoint | `f2e9bd5` adds the proposed Phase 2 design; Codex review run `4C58E6B5-...` reported no findings. |
| 2026-08-20 | Persistence dependency probe | SQLiteData 1.9.0 explicit-database probe passed 3 tests but planned about 807 build units; direct GRDB 7.11.1 (`b83108d...`) passed 2 tests with about 114 build units. Both used `swift test --build-system swiftbuild --no-parallel` in disposable `/tmp/codexreview-{sqlite,grdb}-probe` packages. Direct file-backed `DatabasePool` is selected. |
| 2026-08-20 | History interaction scope complete | #110 restores stable before-anchor reorder; #111 defines a monotonic loaded-ID window, keyset paging, and explicit terminal deletion. |
| 2026-08-20 | Adversarial design audit | Independent persistence/recovery critics drove atomic cross-table observation, attempt isolation, awaited forced close, quiescent import, exact public/API-key/terminal/executable contracts, and per-wave compatibility gates into the design. |
| 2026-08-20 | Phase 2 gate converged | Persistence, recovery-contract, and lifecycle/source-of-truth critics independently reported zero implementation blockers after fail-closed persistence, trigger-specific runtime semantics, typed ingestion containment, one final-result owner, bounded final output, and failed-state close were fixed. |
| 2026-08-20 | Final self-review | Review MCP run `35CF35A6-03DF-4460-8DDF-736C7D8215E4` completed with zero findings: the docs-only recovery contracts were internally consistent and introduced no definite correctness issue. |
| 2026-08-20 | Wave 1 / #103 integrated | `03bf36e` replaces fixed-count bottom scrolling with TextKit 2 viewport-layout completion ownership. Worker validation passed 536 package tests, 15 app tests, and Review MCP with zero findings; integration reran 57 ReviewUIShell tests successfully. |
| 2026-08-20 | Wave 1 / compatibility gates integrated | `3801200` adds a separate four-product consumer, strict four-module `swift-api-digester` baseline, and canonical five-tool MCP golden. Integration aggregate gate passed on Xcode 27 / Swift 6.4. |
| 2026-08-20 | Wave 0 / RecoveryV1 integrated | `9e5bf73`–`59caa59` move default runtime, login staging, saved accounts, future history URL, and preferences behind one RecoveryV1 owner; preparation is owner-only and precedes admission, legacy home is rejected, and Settings no longer advertises it. |
| 2026-08-20 | Wave 0/1 integration green | Compatibility aggregate passed; the full package suite passed 541 tests and the ReviewMonitor app scheme passed 17 tests on the integrated branch. Working tree and both lockfiles remained clean. |
| 2026-08-20 | Wave 0/1 branch review | Review MCP run `83224844-0A69-44C7-B703-6C12D4F74294` reviewed the complete `v0.6.2...HEAD` diff and reported zero findings. |
| 2026-08-20 | Wave 2 source mapping | Upstream `3b45c290` proves review command deltas carry thread/turn/item identity while standalone command/process deltas carry only connection-scoped handles. Wave 2 excludes unregistered standalone traffic instead of porting historical string-equality correlation. |
| 2026-08-20 | Wave 2 / #104 + #105 integrated | `3996456`–`51354e8` pin the current-v2 wire, centralize method/item schema and fault containment, fix canonical outer terminal/result ownership, preserve one visible final row, and expose typed MCP terminal data without changing tool input/schema names. Worker gates passed 604 package tests, 17 app tests, compatibility consumer/API/MCP goldens, and Review MCP run `E8453E0E-...` with zero findings. |
| 2026-08-20 | Wave 3 design gate | `370e431` defines three sequential cancellation/close slices: AppServer barrier, Store/Host/MCP close authority, then ReviewUI/application termination. Independent semantic and API/concurrency re-gates reported zero blockers; after the integration review fix, Wave 3A is pinned to `287795d`. |
| 2026-08-20 | Integrated recovery review fix | Branch review `93B08469-...` found repeated synthetic `.started` events caused by an ungrouped `||`; `287795d` restores the session-owned one-shot invariant and adds a multi-event regression test. The focused AppServer suite passed 161 tests. |
| 2026-08-20 | Integrated recovery review disposition | Review `7E9107A3-...` reported only automatic import of `codexReview.runtimePreferences`. Disputed by the approved RecoveryV1/#108 contract: the legacy key/home are read-only source inputs and automatic reuse could mutate the only current-main state. The explicit quiescent copy/import wave owns validated settings migration. No code change made. |
| 2026-08-20 | Wave 4 persistence slicing | Durable history is split sequentially into 4A schema/writer, 4B atomic query/projection, 4C Store/UI/MCP cutover, and 4D fail-closed/orphan/close insertion. The canonical design now fixes producer/worker join before query/DB close and a single optional preview bootstrap seam; independent re-gate reported zero blockers. Wave 4A remains gated on reviewed Wave 3C. |
| 2026-08-20 | Wave 5 auth/executable design gate | Upstream and live environment evidence fixed nullable-email saved identity, a single API-key slot, crash-atomic RegistryV2/artifact/journal/runtime-lease ownership, finite ChatGPT/API-key reconciliation, Wave 3-owned activation ordering, and one deterministic executable resolver/test seam. Independent API/state-machine re-gate reported zero blockers; implementation remains gated on reviewed Wave 4D. |

## Remaining decisions

- The user approved the Phase 2 design gate on 2026-08-20; implementation may
  proceed on `codex/v0-6-2-recovery`.
- Live MCP probes will determine whether any unreleased `runId` aliases are required; the published v0.6.2 field names remain the default.

## Active implementation slices

| Wave / slice | Budget | Owner boundary | State |
|---|---|---|---|
| Wave 0 / RecoveryV1 environment | 4 hours; 4 production + 4 test files | `CodexReviewHost` composition/runtime paths | Integrated at `9e5bf73`–`59caa59` |
| Wave 1 / #103 log viewport | 3 hours; 2 production + 2 test files | ReviewUI native scroll/layout | Integrated at `03bf36e` |
| Wave 1 / compatibility gates | 5 hours; 10 files | external consumer/API/MCP contract tests | Integrated at `3801200` |
| Wave 2 / #104 + #105 event contract | 18 hours; 10 production + 7 test/gate files | attempt-scoped current-v2 decoder/terminal reducer | Integrated at `3996456`–`51354e8` |
| Wave 3A / #106 interrupt barrier | 17 production + 10 test/gate files maximum | attempt start/cancel + AppServer interrupt/connection terminal owner | Authorized at base `287795d` |
| Wave 3B / #106 runtime close | 18 production + 10 test/gate files maximum | Store runtime generation + Host/MCP public close | Pending reviewed Wave 3A |
| Wave 3C / #106 native close | 12 production + 7 test/gate files maximum | ReviewUI lifecycle + ReviewMonitor termination | Pending reviewed Wave 3B |
| Wave 4A / #102 schema + writer | 24 hours; 12 production/dependency + 4 test files maximum | GRDB database/schema/transaction/global-revision owner | Pending reviewed Wave 3C |
| Wave 4B / #102 query | 24 hours; 8 production + 5 test files maximum | One atomic observation generation + stable projection registry | Pending reviewed Wave 4A |
| Wave 4C / #100/#102/#110/#111 cutover | 40 hours; 31 production + 13 test/gate files maximum | Committed Store/UI/MCP history, duration, paging, reorder, delete | Pending reviewed Wave 4B |
| Wave 4D / #102 lifecycle | 28 hours; 13 production + 9 test/gate files maximum | Fail-closed/orphan recovery + Wave 3 finish/close insertion | Pending reviewed Wave 4C |

The committed worker contract is
[recovery-wave-0-1-task-brief-2026-08-20.md](recovery-wave-0-1-task-brief-2026-08-20.md).
Wave 2 uses
[recovery-wave-2-task-brief-2026-08-20.md](recovery-wave-2-task-brief-2026-08-20.md).
Wave 3 uses
[recovery-wave-3-task-brief-2026-08-20.md](recovery-wave-3-task-brief-2026-08-20.md).
