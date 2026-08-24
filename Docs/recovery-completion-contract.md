# Recovery Completion Contract

This document is the resumable source of truth for completing the ReviewMonitor
recovery tracked by [issue #96](https://github.com/lynnswap/CodexReviewKit/issues/96).
It replaces the oversized implementation plan in PR #117 with owner-scoped,
independently reviewable pull requests.

## Scope

The recovery starts from the published v0.6.2 product contracts and finishes
only when ReviewMonitor has:

- one authoritative review lifecycle and human-facing result;
- ReviewMonitor-owned durable review and log history;
- joined runtime, Store, MCP, and application close lifecycles;
- descriptor-backed RecoveryV1 filesystem authority;
- current executable discovery, ChatGPT login, and API-key activation;
- the published five-tool MCP contract verified with current clients; and
- a Debug ReviewMonitor build verified end to end through its own MCP server.

The four v0.6.2 Swift products remain source-compatible. Existing user state is
never reused as a writable recovery destination.

## Baseline

- Recovery base: v0.6.2 annotated tag object `c8c01d6`, commit `82bddbc`,
  and tree `e7a054b`.
- Exact-tree direct restore: `f554a3b`.
- Current integration anchor: `e382fa8` (PR #154 merged).
- Merged successors are PRs #114, #115, #116, #122–#125, #127, #128,
  #130–#132, #134–#140, and #142–#154. They provide the completed viewport,
  compatibility, terminal/admission, AppServer, runtime-transition, MCP
  transport, Store work-registry, recovery completion-contract, and runtime
  replacement ownership foundations.
- PR #112 was closed without merge. PRs #117, #121, #126, #129, #133, and
  #141 are not integration anchors; #117 remains open as evidence and the
  others were closed as superseded.
- PR #117 is evidence only. It must not be merged or rebased onto `main`.
- PR #117 evidence is frozen at published head `71f289c`. Its preserved
  four-file MCP worktree diff is `+351/-92` with SHA-256
  `1a375791a30928c730531ca8c16ef8d217a687e39695170e98a6c37fb6870194`.
- The rejected Wave 0 branch at `c83e499` is evidence only.

Issue disposition at this anchor:

- completed: #99, #103, #104, #105, #118, and #119;
- explicitly not planned: #101;
- remaining product scope: #97, #98, #100, #102, #106–#111, and #113; and
- shutdown bookkeeping still open: #120 remains open through MCP SDK domain
  and semantic-session shutdown.

Update the integration anchor after each successor merges. A successor is
complete only when its Ready PR has local review with no actionable findings,
an exact-head remote Codex review with no actionable findings, green required
CI, and zero unresolved review threads.

## Owner Map

| State or resource | Target owner | Completion boundary |
| --- | --- | --- |
| Runtime generation and replacement | `CodexReviewStore` plus one `ReviewRuntimeRecoveryReplacement` | Source runtime closed once, replacement outcome replayed, stale generations unable to publish |
| Review attempt to runtime routing | Attempt-route registry in `LiveCodexReviewStoreBackend`; the runtime handle is the route value | Interrupt, recovery, and cleanup use the exact attempt's runtime generation; the route survives replacement through exact cleanup or handoff commit/discard, then is removed once; unknown routes fail visibly |
| Review attempt and recovery receipt | Attempt/replacement registry in `CodexReviewStore`; the worker consumes its receipt | One admission, one current attempt, one typed handoff, and at most one recovery dispatch per receipt; every path reaches `finished` or `suppressed` and removes the receipt after terminal, failure, stop, or application close |
| Registered Store work | `ReviewStoreWorkRegistry` | Admission closes synchronously and one replayable drain joins admitted work |
| MCP HTTP request and response | `MCPHTTPNetworkResourceOwner` | Response source, writer, end acknowledgement, channel, and request task complete before event-loop shutdown |
| MCP SDK domain work and session | Session close owner | SDK server and foreign handler lifetime end before Store session close |
| Store and Host lifetime | Public replayable `CodexReviewStore.close()` and Host close | Concurrent callers receive one ordered close result after Store, runtime, MCP, backend, and persistence drain |
| Durable product history | GRDB-backed history owner inside `CodexReview` | Review terminal and effective logs commit transactionally before cleanup publication |
| RecoveryV1 filesystem authority | Descriptor capability and prepared environment | Creation, validation, handoff, and cleanup remain descriptor-relative and identity-checked |
| Authentication and executable resolution | RegistryV2, login lease, and executable resolver | No secret retention, one joined login lifecycle, and validated runtime activation |
| Window and application termination | ReviewMonitor application lifecycle owner | Quit joins Store close; failure offers explicit Cancel Quit or Quit Anyway semantics |

## Invariants

1. A successful interrupt response is admission, not review completion.
2. A shared runtime failure creates at most one replacement for its source
   generation. Eligible sibling reviews join it rather than creating their own.
3. Every unstructured task and stream has one handle owner, cancellation source,
   terminal reason, and awaited completion.
4. Runtime replacement retains the MCP listener, but never routes a source
   attempt to the replacement backend by inference.
5. Source close completes replacement even when no sibling remains eligible.
   Source-close failure belongs to the initiating caller once and never starts
   a duplicate replacement factory.
6. A recovered run is staged on the destination backend and commits only while
   its exact receipt, attempt, source generation, and replacement generation
   remain current. Earlier canonical terminal, participant cancellation,
   Store stop, or application close discards and cleans the staged destination
   run without overwriting the source terminal.
7. Replacement preparation failure terminates every eligible participant with
   the same failure while retaining the MCP listener.
8. Store close rejects new work before cancellation, drains resources in
   dependency order, and replays one terminal result.
9. The app-server is live transport, not durable history. UI and MCP read the
   same committed product history.
10. Terminal history commits before cleanup can delete or detach source data.
11. Recovery filesystem identity is descriptor-backed. Canonical path strings
   are diagnostics, not mutation authority.
12. Raw API keys never enter observable state, persistence, logs, diagnostics,
   or error descriptions.
13. Sleeps, `Task.yield()` ordering, request counts, and warning filtering are
    not completion proofs. Tests use owner state, receipts, task handles, and
    explicit gates.

## Pull Request Sequence

Keep a normal slice within roughly 2–8 changed files. If an owner cutover grows
beyond that or combines two independently testable responsibilities, split it
before publication. A foundation may land immediately before its consumer, but
must not become a speculative parallel architecture.

### Wave 3 successors for PR #117

1. **Shared replacement state**
   - Replace `RuntimeReplacementContext` with a generation-aware,
     outcome-replaying replacement owner.
   - Integrate it only with the existing manual same-account restart path.
   - Do not add participant enrollment APIs or cancellation/network production
     triggers in this slice.
2. **Attempt runtime routes**
   - Bind successful attempts to exact live runtime handles and route late
     interrupt, legacy recovery, and cleanup to that source generation.
   - Do not add typed-handoff destination staging before the Store recovery
     cutover owns its receipt.
3. **Store initial-attempt cutover**
   - Make the Store worker own and publish the explicit `ReviewStartAdmission`;
     remove the compatibility start path and startup mirror ownership it makes
     redundant.
4. **Store typed recovery receipt and staging**
   - Consume typed recovery candidate/handoff contracts, own exact attempt and
     generation receipts, and stage destination runs without activating shared
     participant replacement yet.
   - Prepare the handoff on the source backend and perform rollback/start on the
     destination backend. Commit or discard only through the exact receipt.
5. **Shared Store recovery activation**
   - Enroll exact-generation siblings and activate one shared replacement from
     cancellation/network triggers without legacy token resume.
   - Preserve the target job's requested terminal, resume each exact-source
     sibling at most once, and suppress natural terminal or cancellation that
     wins during handoff.
   - Complete a replacement with zero siblings, use one factory per source
     generation, and prevent late publication after Store stop.
   - Terminalize every eligible participant with the same replacement failure.
6. **MCP SDK domain drain**
   - Join SDK-created domain handler work with the accepted HTTP operation.
7. **MCP session close owner**
   - Serialize initialize publication, DELETE, and server stop; end the SDK
     server and foreign handler lifetime before Store session close.
8. **Replayable Store and Host close**
   - Compose the Store registry, runtime, MCP, backend, and later persistence
     close into one public result and update the compatibility baseline.
   - Add application-close supersession so staged recovery cannot publish after
     lifetime admission closes.
9. **ReviewUI and application termination**
   - Join window/application termination to Store close and expose explicit
     close-failure decisions.

After successors 1–8 merge and strict MCP shutdown validation passes,
produce a semantic coverage matrix mapping every #117 responsibility and
contract test to a successor PR or an intentionally rejected shape. Close PR
#117 only when that matrix has no unassigned item. Keep #120 open until SDK
domain and session ownership also land. Keep #106 open until durable terminal
commit is complete. Slice 9 is an overall recovery gate, not a #117
supersession prerequisite.

The #117 matrix must also disposition the preserved MCP evidence tests
`foreignSDKLifetimeEndsBeforeStoreSessionClose`,
`stopJoinsInFlightDeleteSessionCloseOwner`, and
`initializingSessionCannotPublishAfterStopBegins`. The response-end
acknowledgement race is already represented by merged PR #144.

### RecoveryV1 and durable history

1. Land issue #113 as descriptor primitives, prepared environment ownership,
   Process handoff revalidation, and a nonescaping `openHistoryDatabase`
   adapter contract. Do not add GRDB in this issue's slices.
2. Add direct GRDB concrete open, schema, migrations, writer transactions,
   receipts, and close in Wave 4A.
3. Add atomic observation and stable projection identity.
4. Cut Store, UI, and MCP reads to committed history; add duration, anchor order,
   paging, and explicit deletion contracts for issues #100, #110, and #111.
5. Commit terminal state before cleanup, fail closed on conflicts, and recover
   orphaned active reviews truthfully. This completes issue #106.

### Authentication, migration, and live compatibility

1. Add RegistryV2, login staging leases, cleanup debt, and startup
   reconciliation.
2. Restore executable discovery for issue #98.
3. Land current ChatGPT callback ownership and API-key activation for issues
   #107 and #97.
4. Verify the five-tool MCP contract, multiple sessions, cancellation, stop,
   restart, and bounded await with current Codex and Claude Code for issue #109.
5. Implement RecoveryV1 copy/import cutover for issue #108 without mutating its
   source. This consumes the reviewed current-client proof rather than preceding
   it.

These issues retain their live acceptance gates:

- #98 requires an executable auto-detected in the user environment and a
  completed ReviewMonitor review using it.
- #107 requires real ChatGPT login, cancellation, external-browser fallback,
  restart, and account selection.
- #97 requires a real API-key-backed login and review plus evidence that the
  secret was not retained.
- #108 requires source and preference before/after byte hashes, independent
  current-main and RecoveryV1 relaunches, and import/retry/rollback proof.

Record provider and artifact identity plus outcome for authentication probes;
never record credentials.

## Validation Per Slice

- `swift test --build-system swiftbuild --no-parallel`
- `scripts/check-compatibility.sh`
- `xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj -scheme CodexReviewMonitor -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
- Focused deterministic repetitions for the modified lifecycle contract.
- Successor 2 asserts route count is zero after exact cleanup. Successor 4
  asserts route count is zero after handoff commit/discard and receipt count is
  zero after terminal/failure. Successor 5 asserts receipt count is zero after
  replacement failure and Store stop. Successor 8 re-runs both zero-count
  contracts after application close.
- `SWIFTNIO_STRICT=1` repeated full MCP runs for MCP shutdown slices, with no
  event-loop-after-shutdown warning.
- Branch-wide local Codex review before publication and after every fix.

## Final Debug and Runtime Gate

The recovery is not complete after automated tests alone. On final `main`:

1. Build ReviewMonitor in Debug with the repository's Xcode project and launch
   that exact build.
2. Use a fresh isolated RecoveryV1 destination and record its identity, the
   exact final-main repository SHA, and the Debug product path.
3. Configure the review model to Luna (`gpt-5.6-luna`) and reasoning effort to
   `medium` through the product settings path. Verify the effective backend
   values; silent fallback is a failed gate.
4. Resolve the endpoint published by that running app and invoke `review_start`
   through the app-owned MCP server with the CodexReviewKit checkout as `cwd`
   and the exact final-main commit as a non-empty commit target. If the result
   is running, call `review_await` explicitly with the same `jobId` until its
   canonical terminal.
5. Exercise `review_read` and `review_list` for that job. Start a separate
   active job, cancel it by exact ID with `review_cancel`, and verify session
   isolation, server restart, and bounded await behavior.
6. Repeat or reference final-main-SHA evidence for the same five-tool contract
   from current Codex and Claude Code.
7. Verify in the visible app that exactly one new product row corresponds to
   the completed job ID, progress and effective logs render normally, no
   reviewer-child JSON is exposed, the final human result is present, terminal
   duration is frozen, and sidebar/detail selection remains coherent.
8. Relaunch the app and verify the committed terminal review remains visible.
9. Reference final-main-SHA evidence for descriptor import, executable
   discovery, real ChatGPT login, real API-key activation, and safe RecoveryV1
   cutover.
10. Close the app and verify the replayed close result, endpoint refusal/session
   termination, app-server PID exit, and that no MCP request/domain task,
   callback, or write survives the joined close boundary.

Record the Debug product path, source SHA, RecoveryV1 identity, client/version,
endpoint, `cwd`, target payload, tool calls, job IDs, effective model and
reasoning effort, terminal results, UI observations, and shutdown evidence in
the final completion report. Do not record credentials.

## Progress Ledger

| Slice | Status | PR / merge |
| --- | --- | --- |
| v0.6.2 recovery foundations through Store work registry | merged | successors listed in Baseline / `9de6dd0` |
| Recovery completion contract | merged | #146 / `9115bdf` |
| Replacement owner and source-close join primitives | merged | #147 / `62e9f80`, #148 / `6cf5212` |
| Store replacement admission and lifecycle owner | merged | #149 / `29e56db`, #150 / `a2dff9b` |
| Store source-close receipt join | merged | #151 / `b28bbe6` |
| Replacement publication transfer | merged | #152 / `d824d72` |
| Attempt runtime routes | merged | #153 / `ef8f02d` |
| Store initial-attempt cutover | merged | #154 / `e382fa8` |
| Admission-less start wrapper cleanup | current slice | — |
| Store typed recovery receipt and staging | pending | — |
| Shared Store recovery activation | pending | — |
| MCP SDK domain drain | pending | — |
| MCP session close owner | pending | — |
| Replayable Store and Host close | pending | — |
| ReviewUI and application termination | pending | — |
| Descriptor-backed RecoveryV1 | pending | #113 |
| Durable history and product cutover | pending | #102, #100, #110, #111 |
| Authentication and executable activation | pending | #97, #98, #107 |
| Current-client MCP proof | pending | #109 |
| Safe state import and cutover | pending | #108 |
| Final Debug/MCP/UI runtime gate | pending | — |
