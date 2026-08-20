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
- #113: descriptor-backed RecoveryV1 filesystem authority.
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
| 2026-08-20 | Historical pre-#113 self-review | Review MCP run `35CF35A6-03DF-4460-8DDF-736C7D8215E4` reported zero findings for the earlier docs. The later four-round filesystem recurrence superseded that conclusion; it is not review evidence for the #113/Wave5 resequencing. |
| 2026-08-20 | #103 independently published | PR #114 merged reviewed source `55f68c0` to restored `main` as `f4c9bb0`. Codex reported no major issue for the exact source commit and CI Package Tests passed. This gate contains neither RecoveryV1 nor compatibility work. |
| 2026-08-20 | Compatibility local proof; independent publication required | Historical `3801200` proves the four-product consumer, strict API baseline, and five-tool MCP golden. It is a separate gate from #103 and must land/review before the current-event public additions. |
| 2026-08-20 | Former Wave 0 superseded | The earlier `9e5bf73`–`59caa59` integrated/green claim and follow-up branch `codex/recovery-wave-0-1-pr@c83e499` are superseded by #113. The path-owned RecoveryV1 implementation is rejected, evidence only, and must not merge. |
| 2026-08-20 | Filesystem stop condition triggered | The same path-ownership invariant recurred across four implementation rounds: `864b16a` → `3b2def2` → `d3f3e20` → `c83e499`. The earlier green test/review evidence did not prove authority against case/Unicode/firmlink identity or path mutation races. No fifth URL/path guard is allowed. |
| 2026-08-20 | Descriptor authority selected | #113 replaces former Wave 0 with `RecoveryEnvironmentPlan` → one `PreparedRecoveryEnvironment`, component `openat`/`fstat` capabilities, descriptor-relative mutation/removal, a Process handoff, and the nonescaping GRDB-adapter contract. Reviewed Wave 3C is its prerequisite; Wave 4A alone implements/tests the adapter, and cannot open GRDB before #113 is reviewed. |
| 2026-08-20 | Wave 2 source mapping | Upstream `3b45c290` proves review command deltas carry thread/turn/item identity while standalone command/process deltas carry only connection-scoped handles. Wave 2 excludes unregistered standalone traffic instead of porting historical string-equality correlation. |
| 2026-08-20 | Wave 2 / #104 + #105 local evidence | `3996456`–`51354e8` pin the current-v2 wire, decoder/containment, canonical result, and typed MCP terminal. The recorded tests/review remain evidence; an independently landed and reviewed current-event HEAD is the only valid Wave 3 base. |
| 2026-08-20 | Wave 3 historical evidence only | `370e431` defines sequential 3A/3B/3C and `202ca65` has 3A code/tests, but its ancestry contains rejected former Wave 0. Even completing its currently blocked review would not qualify it. Replay only the intended 3A diff onto the independently landed/reviewed current-event HEAD, then exact-review that successor as a checkpoint before 3B; 3A is not independently mergeable. |
| 2026-08-21 | PR #117 P1 expands the Wave 3 merge gate | At `d90be363162692ca34b55cd9c2da77109ec852cf`, attempt-local force-close closes the AppServer client shared by sibling reviews, terminalizes siblings, and attempts recovery on the closed client. Wave 3B must add the Store-owned generation/prepare-activate-admission-close seam, one runtime-wide sibling recovery set, one replacement client/backend, MCP listener retention across recoveryReplacement, admitted-handler drain, and public replayable Store close. Old backend is handoff/cleanup-only; new backend is resume-only. Wave 3A+B is one combined exact-base merge gate. |
| 2026-08-21 | Wave 3B owner/close re-gate | Store close—not the AppServer handle—owns Store acquisition/review/rate-limit/cleanup Tasks. The replaceable handle owns only Host auth/reader/router/session/client/process; its one recorded combined close issues the client/process signal before physical completion waiting, and `waitUntilClosed()` idempotently proves the same result. One separate Host app-lifetime MCP owner creates sequential leases: restart/recoveryReplacement retain the listener, runtime-disable stop drains/stops it and later start binds a new generation, and app close is terminal. MCP bind returns the actual post-activation URL (Live port 0 must become nonzero; declared no-MCP conformers return nil, no placeholder). Close preserves nonempty first+all later failures in deterministic order. Once old-runtime close is sent, an open Store creates one replacement even with zero siblings; failure leaves Store runtime admission closed while the existing MCP endpoint exposes typed failure. |
| 2026-08-21 | Wave 3B implementation-boundary re-gate | Wave 3A's `ReviewRuntimeCloseFailure` and `ReviewAttemptProcessor.swift` are frozen. Wave 3B defines a separate `ReviewLifecycleResourceFailure` aggregate in `ReviewRuntimeLifecycle.swift` and carries it independently in `ReviewClosePrimaryFailure`. Host cannot observe AppServer's private notification router/event sessions, so the exact scope adds `AppServerCodexReviewBackend.swift` plus `AppServerClientTests.swift` only for a package close-and-join seam that captures Task/session handles and directly awaits them after client close; Bool polling, `Task.yield()` completion, decoder/reducer/routing changes, and all other AppServer edits remain excluded. |
| 2026-08-20 | Historical integrated-branch review fix | Branch review `93B08469-...` found repeated synthetic `.started` events caused by an ungrouped `||`; `287795d` restores the session-owned one-shot invariant and adds a multi-event regression test. The focused AppServer suite passed 161 tests. This remains implementation evidence until independently landed/reviewed. |
| 2026-08-20 | Historical integrated-branch review disposition | Review `7E9107A3-...` reported only automatic import of `codexReview.runtimePreferences`. The legacy key/home remain read-only source inputs; #108's explicit quiescent descriptor-backed copy/import owns validated settings migration. No code change was made, and the old branch review is not a publication gate. |
| 2026-08-20 | Wave 4 persistence slicing | Durable history remains sequential 4A schema/writer, 4B atomic query/projection, 4C Store/UI/MCP cutover, and 4D fail-closed/orphan/close insertion. 4A now requires both reviewed Wave 3C and reviewed #113; a raw URL GRDB open is non-mergeable. Auth cleanup debt stays outside the history database. |
| 2026-08-20 | Wave 5 auth/executable gate resequenced | Wave 5 remains after reviewed 4D and additionally consumes reviewed Wave 3 close and #113. RegistryV2's authentication disk actor owns one versioned pending/cleanup-debt state; one `LoginStagingLease` owns staging capability plus runtime/client/writer completion and typed close/removal. Bare URLs and log-only cleanup failure are rejected. |
| 2026-08-20 | Wave 7 safe-cutover slicing | #108 is split into quiescent descriptor-backed source snapshot, sanitized exact-ID source adapter, atomic Wave4 import, Wave5 auth/preferences conversion, and admission/rollback/live proof. Implementation remains gated on reviewed #113 and Wave 6 plus Wave4 import and Wave5 RegistryV2 seams. |

## Remaining decisions

- The user approved the Phase 2 design gate on 2026-08-20; implementation may
  proceed on `codex/v0-6-2-recovery` only in the newly recorded predecessor
  order. Former Wave 0/c83 is explicitly excluded.
- Gate V is recorded. Record the reviewed landing SHA for Gate C and the
  current-event gate, the exact 3A checkpoint SHA, the combined 3A+B merge SHA,
  the 3C SHA, and #113 separately. A later review never back-validates an
  earlier checkpoint.
- Live MCP probes will determine whether any unreleased `runId` aliases are required; the published v0.6.2 field names remain the default.

## Active implementation slices

| Wave / slice | Budget | Owner boundary | State |
|---|---|---|---|
| Former Wave 0 / path-owned RecoveryV1 | Retired; zero files | Rejected Environment/path owner | `c83e499` evidence only; must not merge |
| Gate V / #103 log viewport | 3 hours; 2 production + 2 test files | ReviewUI native scroll/layout | Merged PR #114: `55f68c0` → `f4c9bb0`; exact-source Codex review + CI green |
| Gate C / compatibility | 5 hours; 10 test/fixture/script files | external consumer/API/MCP contract tests | Candidate `codex/add-v062-compatibility-gates-pr@94de08f`; independent PR/review pending |
| Wave 2 / #104 + #105 current event | 18 hours; 9 production + 8 test/gate files | attempt-scoped current-v2 decoder/terminal reducer | Local evidence `3996456`–`51354e8`; reviewed landing required before Wave 3 |
| Wave 3A / #106 interrupt barrier | Within 48-hour Wave 3 total; 17 production + 10 test/gate files maximum | attempt start/cancel + AppServer interrupt/connection terminal owner | `202ca65` evidence only; mandatory replay onto reviewed current-event HEAD + exact checkpoint review pending; no independent merge |
| Wave 3B / #106 runtime close | Exact 13 production + 11 test/gate allowed paths | Store-owned work/new lifecycle aggregate + AppServer-owned router/session join seam + replaceable Host handle + app-lifetime sequential MCP-lease owner + zero-sibling replacement + public close | Pending exact 3A checkpoint; combined 3A+B exact-base merge gate required |
| Wave 3C / #106 native close | 12 production + 7 test/gate files maximum | ReviewUI lifecycle + ReviewMonitor termination | Pending reviewed combined Wave 3A+B HEAD |
| Descriptor core / #113 | 24 hours; 8 production + 7 test/gate files maximum | descriptor filesystem, environment plan, Process handoff, GRDB adapter contract | Pending reviewed Wave 3C; blocks Wave 4A and Wave 5 |
| Wave 4A / #102 schema + writer | 24 hours; 12 production/dependency + 4 test files maximum | sole GRDB capability adapter plus database/schema/transaction/global revision | Pending reviewed Wave 3C **and** reviewed #113 |
| Wave 4B / #102 query | 24 hours; 8 production + 5 test files maximum | One atomic observation generation + stable projection registry | Pending reviewed Wave 4A |
| Wave 4C / #100/#102/#110/#111 cutover | 40 hours; 31 production + 13 test/gate files maximum | Committed Store/UI/MCP history, duration, paging, reorder, delete | Pending reviewed Wave 4B |
| Wave 4D / #102 lifecycle | 28 hours; 13 production + 9 test/gate files maximum | Fail-closed/orphan recovery + Wave 3 finish/close insertion | Pending reviewed Wave 4C |
| Wave 5A / auth disk + RegistryV2 | 28 hours; 10 production + 7 test files maximum | immutable artifacts, RegistryV2, atomic authentication state/migration | Pending reviewed Wave 4D and #113 |
| Wave 5B / LoginSession + LoginStagingLease | 28 hours; 10 production + 8 test files maximum | provider-neutral session owner, staging capability, joined resources/close, pending/debt/startup recovery | Pending reviewed Wave 5A |
| Wave 5C / executable | 16 hours; 6 production + 5 test/gate files maximum | executable capability resolver + transport consumption of #113 Process handoff | Pending reviewed Wave 5B |
| Wave 5D / provider + activation | 36 hours; 14 production + 10 test/gate files maximum | ChatGPT/API-key, activation journal, primary runtime lease | Pending reviewed Wave 5C |
| Wave 7A / #108 snapshot | 18 hours; 7 production + 4 test files maximum | Current-main locator, lsof quiescence, manifest, DB/WAL/SHM staging | Pending reviewed Wave 6 |
| Wave 7B1 / #108 source adapter | 28 hours; 9 production + 5 test files maximum | Sanitized exact-ID plain/zstd read + shared normalizer | Pending reviewed Wave 7A |
| Wave 7B2 / #108 history import | 22 hours; 6 production + 5 test files maximum | Deterministic atomic Wave4 import/failure manifest | Pending reviewed Wave 7B1 |
| Wave 7C / #108 auth/preferences | 26 hours; 8 production + 5 test files maximum | Numeric schema 0/1 → RegistryV2 typed import + preference allowlist | Pending reviewed Wave 7B2 |
| Wave 7D / #108 cutover/live proof | 22 hours + live matrix; 7 production + 5 test/gate files maximum | Admission journal, rollback archive, final runtime matrix | Pending reviewed Wave 7C |

The committed worker contract is
[recovery-wave-0-1-task-brief-2026-08-20.md](recovery-wave-0-1-task-brief-2026-08-20.md).
Wave 2 uses
[recovery-wave-2-task-brief-2026-08-20.md](recovery-wave-2-task-brief-2026-08-20.md).
Wave 3 uses
[recovery-wave-3-task-brief-2026-08-20.md](recovery-wave-3-task-brief-2026-08-20.md).
Wave 5 uses
[recovery-wave-5-task-brief-2026-08-20.md](recovery-wave-5-task-brief-2026-08-20.md).
Wave 7 uses
[recovery-wave-7-task-brief-2026-08-20.md](recovery-wave-7-task-brief-2026-08-20.md).
